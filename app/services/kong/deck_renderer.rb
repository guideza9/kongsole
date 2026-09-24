module Kong
  # Places a change_plan's entity into a decK config document -- docs/DESIGN.md
  # section 6 ("เส้นทางของ PR mode", step 3). The file format itself (parse,
  # serialize, the input guard) is Kong::DeckDocument; this class only decides
  # WHERE in it an entity lives and what it may contain. Rule ง (never render an
  # admin-path entity or a consumer credential) is enforced one level up for the
  # first, and here for credentials (see assert_supported!).
  #
  # Where each type goes, and what identifies it, are registry facts
  # (Kong::EntityTypes decK fields); the rules were measured against decK
  # 1.51.1 and 1.66.1 -- docs/superpowers/specs/2026-09-21-m5c-deck-rendering-
  # design.md sections 1 and 4.
  class DeckRenderer
    # A change that cannot be written into decK YAML faithfully. A guardrail
    # Violation, so it surfaces like any other refusal (API 403 / web redirect)
    # rather than a 500 -- and always an error, never a silent omission.
    class Unrenderable < Kong::ChangeGuardrails::Violation; end

    MANAGED = Kong::EntityTypes::KONG_MANAGED_FIELDS

    # A credential is never rendered: decK would sync password hashes back into
    # Kong and break real logins (docs/DESIGN.md section 1.7). Checked on its own
    # so the applier can refuse before it touches git.
    def self.assert_supported!(entity_type)
      return if Kong::EntityTypes.fetch(entity_type).deck_supported?

      raise NotImplementedError, "#{entity_type} is deliberately never rendered into decK YAML " \
        "(credentials are hashed at rest, so a re-sync would corrupt them -- docs/DESIGN.md section 1.7)"
    end

    # Mutates `doc` in place per `change_plan.operation`, then returns it. Where
    # the entity lives, and what matches it, come from the registry
    # (Kong::EntityTypes decK facts); `resolver` names parents. A certificate
    # create mints its own uuid (decK requires an id on certificates, and Kong
    # accepts a client-supplied one), stored on the plan's target_kong_id so
    # the read-model can match the entity once CI syncs it.
    def self.apply_change(doc, change_plan, resolver: Kong::DeckReadModelResolver.new(change_plan.kong_connection))
      assert_supported!(change_plan.entity_type)
      definition = Kong::EntityTypes.fetch(change_plan.entity_type)
      refuse_parent_move!(change_plan, definition)
      list = container(doc, change_plan, resolver)

      case change_plan.operation
      when "create" then create(list, change_plan, definition)
      when "update" then update(list, change_plan, definition)
      when "delete" then delete(list, change_plan, definition)
      else raise Unrenderable, "unknown operation #{change_plan.operation}"
      end

      doc
    end

    def self.create(list, plan, definition)
      entry = renderable(plan.after, definition)
      if plan.entity_type == "certificate"
        entry["id"] = (plan.target_kong_id ||= SecureRandom.uuid)
        raise Unrenderable, "certificate #{entry['id']} is already in this YAML" if list.any? { |existing| existing.is_a?(Hash) && existing["id"] == entry["id"] }
      else
        raise Unrenderable, "a #{plan.entity_type} needs a #{definition.deck_key} to be written into decK YAML" if identity_missing?(plan, definition)
        raise Unrenderable, "#{plan.entity_type} #{identity_label(plan, definition)} is already in this YAML" if find_index(list, plan, definition)
      end

      list << entry
    end
    private_class_method :create

    def self.update(list, plan, definition)
      index = locate!(list, plan, definition)
      refuse_rename_onto_taken!(list, index, plan, definition)
      existing = list[index]
      incoming = keep_redacted(plan.after.except(*MANAGED), plan.before, existing)
      incoming["snis"] = keep_sni_entries(existing["snis"], incoming["snis"]) if plan.entity_type == "certificate" && incoming["snis"].is_a?(Array)

      list[index] = renderable(existing.merge(incoming), definition, keep_id: true)
    end
    private_class_method :update

    # `before` is redacted and Kong::Redactor.prune_marked drops those marks
    # from `after`, so a secret Kong holds arrives here as a missing key. Git
    # holds its value (an env placeholder); keep it, or `deck gateway sync`
    # would clear the secret in Kong. A top-level key already survives the
    # shallow merge in #update -- this covers nested ones (a plugin's config).
    def self.keep_redacted(incoming, before, existing)
      return incoming unless incoming.is_a?(Hash) && before.is_a?(Hash) && existing.is_a?(Hash)

      before.each_with_object(incoming.dup) do |(key, was), acc|
        if was == Kong::Redactor::MARK
          acc[key] = existing[key] if !acc.key?(key) && existing.key?(key)
        elsif was.is_a?(Hash) && acc[key].is_a?(Hash)
          acc[key] = keep_redacted(acc[key], was, existing[key])
        end
      end
    end
    private_class_method :keep_redacted

    # A rename (the identity field differs before and after) must not land on an
    # identity another entry in the list already has: that would write two
    # entries decK cannot tell apart. Never echoes a certificate's PEM.
    def self.refuse_rename_onto_taken!(list, index, plan, definition)
      if plan.entity_type == "ca_certificate"
        old_cert = plan.before["cert"].to_s.strip
        new_cert = plan.after["cert"].to_s.strip
        return if old_cert.blank? || new_cert.blank? || old_cert == new_cert

        taken = list.each_with_index.any? { |entry, i| i != index && entry.is_a?(Hash) && entry["cert"].to_s.strip == new_cert }
        raise Unrenderable, "#{plan.entity_type} #{identity_label(plan, definition)} is already in this YAML" if taken
      else
        key = definition.deck_key
        old_value = plan.before[key].presence
        new_value = plan.after[key].presence
        return if key == "id" || old_value.nil? || new_value.nil? || old_value == new_value

        taken = list.each_with_index.any? { |entry, i| i != index && entry.is_a?(Hash) && entry[key] == new_value }
        raise Unrenderable, "#{plan.entity_type} #{new_value} is already in this YAML" if taken
      end
    end
    private_class_method :refuse_rename_onto_taken!

    def self.delete(list, plan, definition)
      list.delete_at(locate!(list, plan, definition))
    end
    private_class_method :delete

    # Kong returns a certificate's `snis` as names; in YAML each is an entry that
    # may carry its own fields (tags). Keep the entries already there.
    def self.keep_sni_entries(existing, names)
      by_name = Array(existing).select { |entry| entry.is_a?(Hash) }.index_by { |entry| entry["name"] }
      names.map { |name| name.is_a?(Hash) ? name : (by_name[name] || { "name" => name }) }
    end
    private_class_method :keep_sni_entries

    def self.locate!(list, plan, definition)
      raise Unrenderable, "can't tell which #{plan.entity_type} this is (no #{definition.deck_key})" if identity_missing?(plan, definition)

      find_index(list, plan, definition) ||
        raise(Unrenderable, "no #{plan.entity_type} #{identity_description(plan, definition)} in this YAML " \
          "-- it isn't managed through the config repo")
    end
    private_class_method :locate!

    # A certificate is matched by its Kong id. A CA certificate by id when the
    # entry has one, else by its cert text (decK does not require an id there).
    # Everything else by its identity field (`name`, `target`, `username`).
    def self.find_index(list, plan, definition)
      key = definition.deck_key
      if plan.entity_type == "ca_certificate"
        cert = (plan.before["cert"] || plan.after["cert"]).to_s.strip
        list.index do |entry|
          entry.is_a?(Hash) && ((plan.target_kong_id.present? && entry["id"] == plan.target_kong_id) || (cert.present? && entry["cert"].to_s.strip == cert))
        end
      else
        value = identity_value(plan, definition)
        list.index { |entry| entry.is_a?(Hash) && entry[key] == value }
      end
    end
    private_class_method :find_index

    def self.identity_value(plan, definition)
      key = definition.deck_key
      key == "id" ? plan.target_kong_id : (plan.before[key].presence || plan.after[key].presence)
    end
    private_class_method :identity_value

    def self.identity_missing?(plan, definition)
      return false if plan.entity_type == "ca_certificate"

      identity_value(plan, definition).blank?
    end
    private_class_method :identity_missing?

    def self.identity_description(plan, definition)
      plan.entity_type == "ca_certificate" ? identity_label(plan, definition) : "with #{definition.deck_key} #{identity_label(plan, definition)}"
    end
    private_class_method :identity_description

    def self.identity_label(plan, definition)
      plan.entity_type == "ca_certificate" ? "with this cert" : identity_value(plan, definition)
    end
    private_class_method :identity_label

    # The list a change lands in. A child lives inside its parent (decK accepts
    # a target no other way), so the parent has to be in the file already.
    def self.container(doc, plan, resolver)
      case plan.entity_type
      when "route" then child(doc, "services", "name", resolver.name_of(parent_id(plan, "service")), "service", "routes")
      when "target" then child(doc, "upstreams", "name", resolver.name_of(parent_id(plan, "upstream")), "upstream", "targets")
      when "sni" then child(doc, "certificates", "id", parent_id(plan, "certificate"), "certificate", "snis")
      when "plugin" then plugin_container(doc, plan, resolver)
      else top(doc, Kong::EntityTypes.fetch(plan.entity_type).deck_collection)
      end
    end
    private_class_method :container

    def self.plugin_container(doc, plan, resolver)
      scopes = %w[service route consumer].select { |scope| scope_id(plan, scope) }
      raise Unrenderable, "a plugin scoped to #{scopes.join(' and ')} can't be written into decK YAML" if scopes.size > 1
      return top(doc, "plugins") if scopes.empty?

      case scopes.first
      when "service" then child(doc, "services", "name", resolver.name_of(scope_id(plan, "service")), "service", "plugins")
      when "consumer" then child(doc, "consumers", "username", resolver.name_of(scope_id(plan, "consumer")), "consumer", "plugins")
      else
        route_id = scope_id(plan, "route")
        service = child_entry(doc, "services", "name", resolver.name_of(resolver.parent_of(route_id)), "service")
        route = child_entry(service, "routes", "name", resolver.name_of(route_id), "route")
        route["plugins"] = [] unless route["plugins"].is_a?(Array)
        route["plugins"]
      end
    end
    private_class_method :plugin_container

    def self.top(doc, collection)
      doc[collection] = [] unless doc[collection].is_a?(Array)
      doc[collection]
    end
    private_class_method :top

    def self.child(holder, collection, key, value, parent_type, list_name)
      parent = child_entry(holder, collection, key, value, parent_type)
      parent[list_name] = [] unless parent[list_name].is_a?(Array)
      parent[list_name]
    end
    private_class_method :child

    def self.child_entry(holder, collection, key, value, parent_type)
      raise Unrenderable, "can't tell which #{parent_type} this belongs to" if value.blank?

      Array(holder[collection]).find { |entry| entry.is_a?(Hash) && entry[key] == value } ||
        raise(Unrenderable, "the #{parent_type} #{value} isn't in this YAML, so nothing can be nested under it")
    end
    private_class_method :child_entry

    # The parent's Kong id: what the planner stored (a target's upstream), else
    # the reference the entity's own JSON carries (a route's `service`).
    def self.parent_id(plan, reference)
      plan.parent_kong_id.presence || scope_id(plan, reference)
    end
    private_class_method :parent_id

    # Where the change places the entity: a delete removes what `before` says is
    # there, a create or update writes what `after` says. An explicit nil in the
    # chosen side means "no reference" -- it must not fall through to the other
    # side, or a re-scoped plugin would be rendered into its old scope.
    def self.scope_id(plan, reference)
      sides = plan.operation == "delete" ? [ plan.before, plan.after ] : [ plan.after, plan.before ]
      side = sides.find { |attrs| attrs.key?(reference) }
      value = side && side[reference]
      value.is_a?(Hash) ? value["id"] : nil
    end
    private_class_method :scope_id

    # Moving an entity between parents (a plugin between scopes, a route between
    # services, a target between upstreams, an SNI between certificates) would
    # mean removing it from one nesting and writing it into another. That is not
    # implemented, and rendering it under either parent alone would be wrong
    # (the old parent wins silently and the new reference is dropped). So an
    # update whose parent differs -- between before and after, or between the
    # parent the planner recorded and the one after names -- is refused, never
    # approximated. An explicit nil in after counts as "no parent"; a key absent
    # from after means unchanged.
    def self.refuse_parent_move!(plan, definition)
      return unless plan.operation == "update" && definition.deck_refs.any?

      before_parents = definition.deck_refs.map { |ref| reference_id(plan.before[ref]) }
      after_parents = definition.deck_refs.map { |ref| scope_id(plan, ref) }
      recorded = plan.parent_kong_id.presence
      moved = before_parents != after_parents || (recorded && after_parents.compact.any? && !after_parents.include?(recorded))
      return unless moved

      noun = definition.deck_refs.size > 1 ? "scope" : definition.deck_refs.first
      raise Unrenderable, "moving a #{plan.entity_type} between #{noun}s is not supported in PR mode; delete it and create it again"
    end
    private_class_method :refuse_parent_move!

    def self.reference_id(value)
      value.is_a?(Hash) ? value["id"] : nil
    end
    private_class_method :reference_id

    # What a document may hold once it is a decK entry: no Kong bookkeeping, no
    # reference to the parent it is nested inside, and no nulls -- decK rejects
    # `custom_id: null` (measured, M5c) and Kong returns nulls constantly.
    def self.renderable(attrs, definition, keep_id: false)
      managed = keep_id ? MANAGED - %w[id] : MANAGED
      cleaned = compact(attrs.except(*managed, *definition.deck_refs))
      cleaned["snis"] = cleaned["snis"].map { |sni| sni.is_a?(Hash) ? sni : { "name" => sni } } if cleaned["snis"].is_a?(Array)
      cleaned
    end
    private_class_method :renderable

    def self.compact(node)
      case node
      when Hash then node.each_with_object({}) { |(key, value), result| result[key] = compact(value) unless value.nil? }
      when Array then node.map { |value| compact(value) }
      else node
      end
    end
    private_class_method :compact
  end
end
