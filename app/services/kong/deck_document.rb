module Kong
  # The decK state file: parse, deterministic serialize, and the fail-closed
  # guard on the input -- docs/DESIGN.md section 6's iron rules:
  #   ก. always build the YAML from git, never from `deck gateway dump`
  #   ข. `_info.select_tags` is mandatory (deck gateway sync deletes anything
  #      untagged)
  #   ค. serialize(parse(x)) == x, byte for byte
  # Every format decision below was measured against decK 1.51.1 and 1.66.1
  # (docs/superpowers/specs/2026-09-21-m5c-deck-rendering-design.md section 1).
  class DeckDocument
    # The file would not survive a re-render unchanged (or is not YAML). A
    # guardrail refusal like any other, so it surfaces as one (403 / redirect).
    class Unparseable < Kong::ChangeGuardrails::Violation; end

    FORMAT_VERSION = "3.0"
    # The collections the tool manages, in the order they are written. Anything
    # else the file holds (vaults, consumer_groups, flat routes, ...) follows,
    # sorted, and is kept verbatim: decK's schema is closed, so what it accepts
    # is decK's call -- `deck file validate` decides, not this class.
    COLLECTION_ORDER = %w[services upstreams certificates ca_certificates consumers plugins].freeze
    # Written first inside any mapping, so an entity reads by what names it.
    IDENTITY_KEYS = %w[name username target id].freeze
    DECK_ENV_REFERENCE = /\A\$\{\{ env "DECK_[A-Z0-9_]+" \}\}\z/

    # Builds the working document. `text` is nil/blank the first time a
    # connection's config repo has no file yet. Adds no collection keys.
    def self.parse(text, select_tags:)
      doc = text.present? ? YAML.safe_load(text) : {}
      doc = {} unless doc.is_a?(Hash)
      doc["_format_version"] ||= FORMAT_VERSION
      doc["_info"] = doc["_info"].is_a?(Hash) ? doc["_info"] : {}
      doc["_info"]["select_tags"] = Array(select_tags)
      doc
    rescue Psych::Exception => e
      raise Unparseable, "the config YAML can't be parsed (#{e.class})"
    end

    # Rule ค, applied to the INPUT. If a re-render would not reproduce the file,
    # it would silently rewrite or drop part of it -- and `deck gateway sync`
    # deletes whatever is absent -- so refuse before anything is written.
    def self.verify_input!(text)
      return if text.blank?

      rendered = serialize(parse(text, select_tags: file_select_tags(text)))
      return if rendered == text || rendered == without_legacy_empty_collections(text)

      raise Unparseable, "the config YAML would not survive a re-render unchanged (#{first_difference(text, rendered)}) " \
        "-- comments, anchors and hand formatting can't be preserved; rewrite it in the tool's format first"
    end

    def self.serialize(doc)
      lines = [ "_format_version: #{scalar(doc.fetch('_format_version', FORMAT_VERSION))}", "_info:", "  select_tags:" ]
      Array(doc.dig("_info", "select_tags")).each { |tag| lines << "    - #{scalar(tag)}" }
      top_level_keys(doc).each { |key| lines.concat(entry_lines(key, doc[key], 0)) }
      "#{lines.join("\n")}\n"
    end

    # An empty managed collection is left out: decK rejects a bare `services:`
    # (null), and Kong has nothing to sync for it anyway.
    def self.top_level_keys(doc)
      rest = (doc.keys - %w[_format_version _info]).reject { |key| COLLECTION_ORDER.include?(key) && doc[key].blank? }
      known = COLLECTION_ORDER & rest
      known + (rest - known).sort
    end
    private_class_method :top_level_keys

    # One `key: value` entry at `indent` columns, whatever the value is.
    def self.entry_lines(key, value, indent)
      pad = " " * indent
      case value
      when Array then array_lines(key, value, indent)
      when Hash
        return [ "#{pad}#{key}: {}" ] if value.empty?

        [ "#{pad}#{key}:" ] + mapping_lines(value, indent + 2)
      when String
        value.include?("\n") ? block_lines(key, value, indent) : [ "#{pad}#{key}: #{scalar(value)}" ]
      else
        [ "#{pad}#{key}: #{scalar(value)}" ]
      end
    end
    private_class_method :entry_lines

    def self.mapping_lines(hash, indent)
      ordered_keys(hash).flat_map { |key| entry_lines(key, hash[key], indent) }
    end
    private_class_method :mapping_lines

    def self.array_lines(key, items, indent)
      pad = " " * indent
      return [ "#{pad}#{key}: []" ] if items.empty?

      lines = [ "#{pad}#{key}:" ]
      items.each do |item|
        if item.is_a?(Hash) && item.any?
          body = mapping_lines(item, indent + 4)
          lines << "#{pad}  - #{body.first.lstrip}"
          lines.concat(body.drop(1))
        else
          lines << "#{pad}  - #{item.is_a?(Hash) ? '{}' : scalar(item)}"
        end
      end
      lines
    end
    private_class_method :array_lines

    # A multi-line string (a PEM) as a literal block, so it stays readable and
    # round-trips exactly. Falls back to a quoted scalar when a block cannot
    # hold it faithfully (leading whitespace, several trailing newlines).
    def self.block_lines(key, value, indent)
      pad = " " * indent
      body = value.delete_suffix("\n")
      faithful = !body.end_with?("\n") && body.lines.none? { |line| line.start_with?(" ") || line.start_with?("\t") }
      return [ "#{pad}#{key}: #{scalar(value)}" ] unless faithful

      chomp = value.end_with?("\n") ? "|" : "|-"
      [ "#{pad}#{key}: #{chomp}" ] + body.split("\n", -1).map { |line| line.empty? ? "" : "#{pad}  #{line}" }
    end
    private_class_method :block_lines

    def self.ordered_keys(hash)
      first = IDENTITY_KEYS.select { |key| hash.key?(key) }
      first + (hash.keys - first).sort_by(&:to_s)
    end
    private_class_method :ordered_keys

    # decK substitutes its env placeholder as TEXT before it parses YAML, so the
    # reference must reach the file exactly as decK expects it: in single quotes
    # (the one form both decK and a YAML parser accept -- measured, M5c).
    # `line_width: -1` stops Psych folding a long value across lines.
    def self.scalar(value)
      return "null" if value.nil?
      return "'#{value}'" if value.is_a?(String) && DECK_ENV_REFERENCE.match?(value)

      YAML.dump(value, line_width: -1).delete_prefix("---").strip
    end
    private_class_method :scalar

    # Before M5c the tool wrote a bare `services:` for an empty file -- a line
    # decK itself rejects (it was never validated: DeckCli was stubbed). The
    # re-render drops it; that is the one difference from a file the tool wrote
    # that the guard must not treat as data loss.
    def self.without_legacy_empty_collections(text)
      text.gsub(/^(?:#{COLLECTION_ORDER.join('|')}):[ \t]*\r?\n/, "")
    end
    private_class_method :without_legacy_empty_collections

    # The file's own tags, so the guard compares like with like: parse would
    # otherwise overwrite them and a stale tag list would read as data loss.
    def self.file_select_tags(text)
      Array(YAML.safe_load(text).then { |doc| doc.is_a?(Hash) ? doc.dig("_info", "select_tags") : nil })
    rescue Psych::Exception
      []
    end
    private_class_method :file_select_tags

    def self.first_difference(original, rendered)
      a = original.lines
      b = rendered.lines
      index = (0...[ a.size, b.size ].max).find { |i| a[i] != b[i] }
      index ? "first difference at line #{index + 1}" : "trailing whitespace differs"
    end
    private_class_method :first_difference
  end
end
