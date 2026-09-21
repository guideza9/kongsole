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
    # How a placeholder reads in the FILE: `key: "${{ env "DECK_X" }}"`. That is
    # not YAML Ruby can parse (the inner quotes end the scalar), so `load_yaml`
    # swaps each one for a sentinel scalar first and maps it back afterwards.
    DECK_ENV_FILE_FORM = /"\$\{\{ env "(DECK_[A-Z0-9_]+)" \}\}"/
    SENTINEL_PREFIX = "__KONGSOLE_DECK_ENV__".freeze
    SENTINEL = /\A#{SENTINEL_PREFIX}(DECK_[A-Z0-9_]+)__\z/

    # Builds the working document. `text` is nil/blank the first time a
    # connection's config repo has no file yet. Adds no collection keys.
    def self.parse(text, select_tags:)
      doc = text.present? ? load_yaml(text) : {}
      doc = {} unless doc.is_a?(Hash)
      doc["_format_version"] ||= FORMAT_VERSION
      doc["_info"] = doc["_info"].is_a?(Hash) ? doc["_info"] : {}
      doc["_info"]["select_tags"] = Array(select_tags)
      doc
    rescue Psych::Exception => e
      raise Unparseable, "the config YAML can't be parsed (#{e.class})"
    end

    # YAML.safe_load with decK's env placeholders understood: each one becomes a
    # plain `${{ env "DECK_X" }}` String in the result, exactly what
    # Kong::CertificateKeyPolicy.deck_reference? recognises. A file that already
    # holds the sentinel text is refused outright (nothing of it is echoed): it
    # could otherwise smuggle a value in as a "reference".
    def self.load_yaml(text)
      raise Unparseable, "the config YAML can't be parsed (it contains reserved text)" if text.include?(SENTINEL_PREFIX)

      restore_references(YAML.safe_load(text.gsub(DECK_ENV_FILE_FORM) { %("#{SENTINEL_PREFIX}#{Regexp.last_match(1)}__") }))
    end
    private_class_method :load_yaml

    # A sentinel that is not the WHOLE string (the file quoted the placeholder
    # inside a longer value) can't be represented faithfully: refuse it.
    def self.restore_references(value)
      case value
      when Hash then value.to_h { |key, item| [ restore_references(key), restore_references(item) ] }
      when Array then value.map { |item| restore_references(item) }
      when String then restore_string(value)
      else value
      end
    end
    private_class_method :restore_references

    def self.restore_string(value)
      return value unless value.include?(SENTINEL_PREFIX)

      match = SENTINEL.match(value)
      raise Unparseable, "the config YAML can't be parsed (a decK placeholder sits inside a longer string)" unless match

      %(${{ env "#{match[1]}" }})
    end
    private_class_method :restore_string

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
      lines = [ "_format_version: #{scalar(doc.fetch('_format_version', FORMAT_VERSION))}" ]
      lines.concat(info_lines(doc["_info"]))
      top_level_keys(doc).each { |key| lines.concat(entry_lines(key, doc[key], 0)) }
      "#{lines.join("\n")}\n"
    end

    # `select_tags` first, then whatever else `_info` holds (decK's `defaults`),
    # sorted and kept. An empty `select_tags` is written `[]`: decK rejects the
    # bare null a naive writer would produce (measured, 1.51.1 and 1.66.1). An empty
    # list means "no filter" to decK: Kong::ChangeApplier#require_select_tags! refuses it first.
    def self.info_lines(info)
      info = info.is_a?(Hash) ? info : {}
      info = info.merge("select_tags" => Array(info["select_tags"]))
      keys = [ "select_tags" ] + (info.keys - [ "select_tags" ]).sort_by(&:to_s)
      [ "_info:" ] + keys.flat_map { |key| entry_lines(key, info[key], 2) }
    end
    private_class_method :info_lines

    # An empty managed collection is left out: decK rejects a bare `services:`
    # (null), and Kong has nothing to sync for it anyway.
    def self.top_level_keys(doc)
      rest = (doc.keys - %w[_format_version _info]).reject { |key| COLLECTION_ORDER.include?(key) && doc[key].blank? }
      known = COLLECTION_ORDER & rest
      known + (rest - known).sort_by(&:to_s)
    end
    private_class_method :top_level_keys

    # One `key: value` entry at `indent` columns, whatever the value is.
    def self.entry_lines(key, value, indent)
      pad = " " * indent
      key = key_text(key)
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

      [ "#{pad}#{key}:" ] + sequence_lines(items, indent + 2)
    end
    private_class_method :array_lines

    # The `- item` lines of a sequence whose dashes sit at `dash_indent`. An
    # item that is itself a mapping or a sequence is written nested, with its
    # first line sharing the dash, so it re-parses to the same value.
    def self.sequence_lines(items, dash_indent)
      pad = " " * dash_indent
      items.flat_map do |item|
        body =
          if item.is_a?(Hash) && item.any? then mapping_lines(item, dash_indent + 2)
          elsif item.is_a?(Array) && item.any? then sequence_lines(item, dash_indent + 2)
          else [ "#{pad}  #{empty_or_scalar(item)}" ]
          end
        [ "#{pad}- #{body.first.lstrip}" ] + body.drop(1)
      end
    end
    private_class_method :sequence_lines

    def self.empty_or_scalar(item)
      return "{}" if item.is_a?(Hash)
      return "[]" if item.is_a?(Array)

      scalar(item)
    end
    private_class_method :empty_or_scalar

    # Every key is a string: a bare `123:` or `true:` reads back as another
    # type, so the file would not survive a re-render (and decK's schema has no
    # such keys). Quoted when a bare key would read as something else.
    def self.key_text(key)
      raise Unparseable, "the config YAML has a key that is not a string (#{key.inspect}); decK files only use string keys" unless key.is_a?(String)

      scalar(key)
    end
    private_class_method :key_text

    # What a literal block keeps exactly. YAML normalises every line break it
    # knows (\r, \r\n, NEL, LS, PS) to \n inside a block scalar and refuses
    # control characters, so a string holding any of those cannot use one.
    SAFE_TEXT = /\A[\n\t\u0020-\u007E\u00A0-\u2027\u202A-\uD7FF\uE000-\uFEFE\uFF00-\uFFFD\u{10000}-\u{10FFFF}]*\z/

    # A multi-line string (a PEM) as a literal block, so it stays readable and
    # round-trips exactly. Falls back to a double-quoted scalar when a block
    # cannot hold it faithfully (carriage returns, other line-break characters,
    # leading whitespace, several trailing newlines, nothing but newlines).
    def self.block_lines(key, value, indent)
      pad = " " * indent
      body = value.delete_suffix("\n")
      faithful = body.present? && !body.end_with?("\n") && SAFE_TEXT.match?(value) &&
                 body.lines.none? { |line| line.start_with?(" ") || line.start_with?("\t") }
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
    # reference is written for decK, not for a YAML parser: double-quoted with
    # the inner quotes bare, `"${{ env "DECK_X" }}"`. CI supplies the PEM on ONE
    # line with literal `\n` escapes; after substitution the file holds a normal
    # double-quoted scalar and YAML decodes the escapes into the real key. The
    # single-quoted form never delivers a usable key (Kong: "invalid key:
    # pkey.new:load_key") -- measured on Kong 3.7 with decK 1.51.1 and 1.66.1
    # (spec section 9). Ruby can't read this text back as-is, hence `load_yaml`.
    # `line_width: -1` stops Psych folding a long value across lines. A string
    # Psych would spread over several lines is double-quoted instead, so a
    # scalar is always one line. Only what a YAML file can hold as a plain
    # scalar is accepted; anything else is refused rather than written wrongly.
    def self.scalar(value)
      return "null" if value.nil?
      return %("#{value}") if value.is_a?(String) && DECK_ENV_REFERENCE.match?(value)
      raise Unparseable, "the value #{value.inspect} can't be written as decK YAML (#{value.class})" unless renderable?(value)

      return double_quoted(value) if value.is_a?(String) && !SAFE_TEXT.match?(value)

      dumped = YAML.dump(value, line_width: -1).delete_prefix("---").strip
      dumped.include?("\n") ? double_quoted(value) : dumped
    end
    private_class_method :scalar

    def self.renderable?(value)
      [ String, Integer, Float, TrueClass, FalseClass ].any? { |type| value.is_a?(type) }
    end
    private_class_method :renderable?

    # libyaml does the escaping (\n, \r, \u2028, control characters ...).
    def self.double_quoted(value)
      node = Psych::Nodes::Scalar.new(value, nil, nil, false, true, Psych::Nodes::Scalar::DOUBLE_QUOTED)
      document = Psych::Nodes::Document.new.tap { |doc| doc.children << node }
      Psych::Nodes::Stream.new.tap { |stream| stream.children << document }.to_yaml(nil, line_width: -1).delete_prefix("--- ").chomp
    end
    private_class_method :double_quoted

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
      Array(load_yaml(text).then { |doc| doc.is_a?(Hash) ? doc.dig("_info", "select_tags") : nil })
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
