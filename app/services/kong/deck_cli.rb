require "open3"
require "base64"

module Kong
  # Shells out to the `deck` CLI to check a rendered YAML file and diff it
  # against a connection's live Kong, using the *read-only* credential already
  # held for the session -- deck never gets a write credential, since PR mode's
  # whole point is that the tool itself cannot write to uat/prod Kong
  # (docs/DESIGN.md section 6 step 4 note).
  #
  # Every invocation below was measured against decK 1.51.1 and 1.66.1 (the two
  # behave identically -- docs/superpowers/specs/2026-09-21-m5c-deck-rendering-
  # design.md section 1): the state file is a POSITIONAL argument (there is no
  # `-s`), and the offline check is `deck file validate` -- `deck gateway
  # validate` is an online command that needs a live Kong.
  class DeckCli
    class Error < StandardError; end

    # decK substitutes `${{ env "DECK_X" }}` as TEXT before it parses the file,
    # and both commands below run on this host, so each referenced variable must
    # exist. The real private key must never be here (M5b), so each one gets
    # this dummy; CI resolves the real value. Any single-line value validates.
    PLACEHOLDER_VALUE = "kongsole-validation-placeholder".freeze
    ENV_REFERENCE = /\$\{\{ env "(DECK_[A-Z0-9_]+)" \}\}/
    MAX_MESSAGE = 2000

    def self.validate(file_path)
      new.validate(file_path)
    end

    def self.diff(file_path, connection:, secret:)
      new.diff(file_path, connection: connection, secret: secret)
    end

    def validate(file_path)
      _stdout, stderr, status = run([ "file", "validate", file_path.to_s ], file_path)
      raise Error, "deck file validate failed: #{clean(stderr)}" unless status.success?

      true
    end

    def diff(file_path, connection:, secret:)
      args = [
        "gateway", "diff", file_path.to_s,
        "--kong-addr", connection.admin_url,
        "--headers", "Authorization:#{basic_auth(connection.auth_username, secret)}",
        "--json-output"
      ]
      stdout, stderr, status = run(args, file_path)
      raise Error, "deck gateway diff failed: #{clean(stderr)}" unless status.success?

      parse_diff(stdout)
    end

    private

    # A fixed message: unparseable output can hold file content, so none of it is echoed.
    def parse_diff(stdout)
      stdout.blank? ? {} : JSON.parse(stdout)
    rescue JSON::ParserError
      raise Error, "deck gateway diff did not return JSON"
    end

    def bin
      ENV["DECK_BIN"].presence || "deck"
    end

    def run(args, file_path)
      Open3.capture3(placeholder_env(file_path), bin, *args)
    rescue Errno::ENOENT
      raise Error, "the deck binary (#{bin}) wasn't found -- install decK or point DECK_BIN at it"
    end

    def placeholder_env(file_path)
      text = File.exist?(file_path) ? File.read(file_path) : ""
      text.scan(ENV_REFERENCE).flatten.uniq.to_h { |name| [ name, PLACEHOLDER_VALUE ] }
    end

    # decK's own message is what an operator needs; a pasted private key is
    # never allowed through (M5b), and a runaway message is cut.
    def clean(stderr)
      Kong::CertificateKeyPolicy.scrub(stderr).strip.truncate(MAX_MESSAGE)
    end

    def basic_auth(username, secret)
      "Basic #{Base64.strict_encode64("#{username}:#{secret}")}"
    end
  end
end
