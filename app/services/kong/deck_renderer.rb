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
  # Scope matches M1's entity surface: services only. Routes/consumers/
  # plugins arrive in M3/M4.
  class DeckRenderer
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

    # Mutates `doc["services"]` in place per `change_plan.operation`, matched
    # by service name (decK YAML doesn't carry Kong's own uuid once created
    # here -- see Kong::EntityTypes::KONG_MANAGED_FIELDS). Returns doc for
    # chaining.
    def self.apply_change(doc, change_plan)
      services = doc["services"]
      name = change_plan.before["name"] || change_plan.after["name"]
      raise ArgumentError, "change_plan has no service name to match on" if name.blank?

      index = services.index { |s| s["name"] == name }

      case change_plan.operation
      when "create"
        raise ArgumentError, "a service named #{name} already exists in this YAML" if index
        services << renderable(change_plan.after)
      when "update"
        raise ArgumentError, "no service named #{name} found in this YAML to update" unless index
        services[index] = renderable(services[index].merge(change_plan.after))
      when "delete"
        raise ArgumentError, "no service named #{name} found in this YAML to delete" unless index
        services.delete_at(index)
      else
        raise ArgumentError, "unknown operation #{change_plan.operation}"
      end

      doc
    end

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

    def self.renderable(attrs)
      attrs.except(*Kong::EntityTypes::KONG_MANAGED_FIELDS)
    end
    private_class_method :renderable

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
