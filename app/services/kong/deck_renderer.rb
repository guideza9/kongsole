module Kong
  # Parses, mutates, and serializes a connection's decK config YAML --
  # docs/DESIGN.md section 6 ("เส้นทางของ PR mode", steps 2-3) and its four
  # "กฎเหล็ก" (iron rules):
  #   ก. always build the YAML from git, never from `deck gateway dump`
  #   ข. `_info.select_tags` is mandatory (deck gateway sync deletes anything
  #      untagged)
  #   ค. round-trip serialize(parse(x)) == x, byte for byte, from M2 on
  #   ง. never render an admin-path entity or a consumer credential
  #
  # Rule ง's enforcement lives one level up, in Kong::ChangeApplier: a
  # change_plan targeting an admin-path kong_id is refused before it ever
  # reaches this renderer, so no admin-path entity is ever proposed into
  # YAML in the first place (see ChangeApplier#execute_pr!).
  #
  # apply_change places every managed entity type (services, routes,
  # upstreams, targets, consumers, plugins, certificates, SNIs, CA
  # certificates) per the registry; credentials are never rendered.
  class DeckRenderer
    # A change that cannot be written into decK YAML faithfully. A guardrail
    # Violation, so it surfaces like any other refusal (API 403 / web redirect)
    # rather than a 500 -- and always an error, never a silent omission.
    class Unrenderable < Kong::ChangeGuardrails::Violation; end

    FORMAT_VERSION = "3.0"

    # Builds (or re-derives) the working document for a connection's YAML
    # file. `yaml_text` is nil/blank the first time a connection's config
    # repo doesn't have the file yet -- callers get a valid empty skeleton
    # either way.
    def self.parse(yaml_text, select_tags:)
      doc = yaml_text.present? ? (YAML.safe_load(yaml_text) || {}) : {}
      doc = {} unless doc.is_a?(Hash)
      doc["_format_version"] ||= FORMAT_VERSION
      doc["_info"] = (doc["_info"].is_a?(Hash) ? doc["_info"] : {})
      doc["_info"]["select_tags"] = Array(select_tags)
      doc["services"] = Array(doc["services"])
      doc
    end

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
      else
        raise Unrenderable, "a #{plan.entity_type} needs a #{definition.deck_key} to be written into decK YAML" if identity_missing?(plan, definition)
        raise Unrenderable, "#{plan.entity_type} #{identity_label(plan, definition)} is already in this YAML" if find_index(list, plan, definition)
      end

      list << entry
    end
    private_class_method :create

    def self.update(list, plan, definition)
      index = locate!(list, plan, definition)
      existing = list[index]
      incoming = plan.after.except(*MANAGED)
      incoming["snis"] = keep_sni_entries(existing["snis"], incoming["snis"]) if plan.entity_type == "certificate" && incoming["snis"].is_a?(Array)

      list[index] = renderable(existing.merge(incoming), definition, keep_id: true)
    end
    private_class_method :update

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
        raise(Unrenderable, "no #{plan.entity_type} with #{definition.deck_key} #{identity_label(plan, definition)} in this YAML " \
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

    def self.scope_id(plan, reference)
      value = plan.after[reference] || plan.before[reference]
      value.is_a?(Hash) ? value["id"] : nil
    end
    private_class_method :scope_id

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

    # Deterministic YAML writer -- not bare Psych.dump, whose key ordering
    # isn't controllable -- so that a no-op parse+serialize round trip (rule
    # ค) and repeated runs both produce byte-identical output, keeping PR
    # diffs limited to the actual change instead of reformatting noise.
    def self.serialize(doc)
      lines = []
      lines << "_format_version: #{scalar(doc.fetch('_format_version', FORMAT_VERSION))}"
      lines << "_info:"
      lines << "  select_tags:"
      Array(doc.dig("_info", "select_tags")).each { |tag| lines << "    - #{scalar(tag)}" }
      lines << "services:"
      Array(doc["services"]).each do |service|
        lines.concat(service_lines(service))
      end
      "#{lines.join("\n")}\n"
    end

    def self.service_lines(service)
      ordered_keys = [ "name", *(service.keys - [ "name" ]).sort ]
      first = true
      lines = []
      ordered_keys.each do |key|
        value = service[key]
        prefix = first ? "  - " : "    "
        first = false
        lines.concat(value_lines(key, value, prefix, "    "))
      end
      lines
    end
    private_class_method :service_lines

    def self.value_lines(key, value, prefix, indent)
      if value.is_a?(Array)
        return [ "#{prefix}#{key}: []" ] if value.empty?

        lines = [ "#{prefix}#{key}:" ]
        value.each { |item| lines << "#{indent}  - #{scalar(item)}" }
        lines
      elsif value.is_a?(Hash)
        lines = [ "#{prefix}#{key}:" ]
        value.keys.sort.each { |k| lines.concat(value_lines(k, value[k], "#{indent}  ", "#{indent}  ")) }
        lines
      else
        [ "#{prefix}#{key}: #{scalar(value)}" ]
      end
    end
    private_class_method :value_lines

    # Leans on Psych's own scalar-quoting logic (only quotes when a bare
    # value would parse ambiguously) rather than reimplementing YAML's
    # quoting rules, while this class keeps full control of structure/order.
    def self.scalar(value)
      return "null" if value.nil?

      YAML.dump(value).delete_prefix("---").strip
    end
    private_class_method :scalar
  end
end
