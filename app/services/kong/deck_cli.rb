require "open3"
require "base64"

module Kong
  # Shells out to the `deck` CLI (v1.51.1, `deck gateway ...` subcommand
  # syntax -- docs/DESIGN.md section 6) to validate a rendered YAML file and
  # diff it against a connection's live Kong state, using the *read-only*
  # credential already held for the session -- deck never gets a write
  # credential, since PR-mode's whole point is that the tool itself cannot
  # write to uat/prod Kong (docs/DESIGN.md section 6 step 4 note).
  class DeckCli
    class Error < StandardError; end

    def self.validate(file_path)
      new.validate(file_path)
    end

    def self.diff(file_path, connection:, secret:)
      new.diff(file_path, connection: connection, secret: secret)
    end

    def validate(file_path)
      _stdout, stderr, status = Open3.capture3("deck", "gateway", "validate", "-s", file_path.to_s)
      raise Error, "deck gateway validate failed: #{stderr.presence}" unless status.success?

      true
    end

    def diff(file_path, connection:, secret:)
      cmd = [
        "deck", "gateway", "diff", "-s", file_path.to_s,
        "--kong-addr", connection.admin_url,
        "--headers", "Authorization:#{basic_auth(connection.auth_username, secret)}",
        "--json-output"
      ]
      stdout, stderr, status = Open3.capture3(*cmd)
      raise Error, "deck gateway diff failed: #{stderr.presence}" unless status.success?

      stdout.blank? ? {} : JSON.parse(stdout)
    end

    private

    def basic_auth(username, secret)
      "Basic #{Base64.strict_encode64("#{username}:#{secret}")}"
    end
  end
end
