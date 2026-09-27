module Kong
  # One export (R7): check the tags, `deck gateway dump` them from this
  # connection's Kong, sanitize, and record who exported -- the file itself is
  # never stored, only its sha256 and size (CLAUDE.md rule 2's exception). The
  # web page and the agent API (kong_export) both come through here, so there
  # is one sanitizer for both.
  class ConfigExport
    # Kong changed between the preview and the download: the new file is
    # carried so it can be shown, and nothing was recorded or handed over.
    class Changed < StandardError
      attr_reader :result

      def initialize(result)
        super("Kong changed since the preview")
        @result = result
      end
    end

    def self.call(connection:, secret:, select_tags:, actor_username:, actor_operator:, actor_kind: "human", record: true,
                  expected_sha256: nil)
      new(connection: connection, secret: secret, select_tags: select_tags).call(
        actor_username: actor_username, actor_operator: actor_operator, actor_kind: actor_kind, record: record,
        expected_sha256: expected_sha256
      )
    end

    def initialize(connection:, secret:, select_tags:)
      @connection = connection
      @secret = secret
      @select_tags = Kong::ExportSanitizer.validate_tags!(select_tags)
    end

    # `record: false` is the preview: nothing leaves the page, so nothing is logged.
    # `expected_sha256` is the preview's digest: the download is that file or nothing.
    def call(actor_username:, actor_operator:, actor_kind:, record:, expected_sha256: nil)
      text = Kong::DeckCli.dump(connection: @connection, secret: @secret, select_tags: @select_tags)
      result = Kong::ExportSanitizer.call(text, connection: @connection, select_tags: @select_tags, secret_paths_for: secret_paths_for)
      raise Changed, result if expected_sha256 && Digest::SHA256.hexdigest(result.yaml) != expected_sha256

      audit(result, actor_username, actor_operator, actor_kind) if record
      result
    end

    private

    # Each plugin's secret fields from its own schema on this connection;
    # nil (the sanitizer fails closed) when Kong won't say.
    def secret_paths_for
      client = Kong::Client.new(connection: @connection, secret: @secret)
      fields = Kong::PluginSecretFields.new
      ->(plugin_name) { fields.fetch(client: client, plugin_name: plugin_name) }
    end

    def audit(result, actor_username, actor_operator, actor_kind)
      AuditEvent.create!(
        kong_connection: @connection, operation: "export", entity_type: "config",
        actor_username: actor_username, actor_operator: actor_operator, actor_kind: actor_kind,
        context: {
          "select_tags" => @select_tags,
          "sha256" => Digest::SHA256.hexdigest(result.yaml),
          "bytes" => result.yaml.bytesize
        }
      )
    end
  end
end
