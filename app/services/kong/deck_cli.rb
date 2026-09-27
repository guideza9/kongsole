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

    # Kong could not be reached from this machine (R7.1): each project sits on
    # its own network, so this reads as "join the VPN", not "decK failed".
    class Unreachable < Error
      attr_reader :kind

      def initialize(message = nil, kind: :other)
        super(message)
        @kind = kind
      end
    end

    # decK substitutes `${{ env "DECK_X" }}` as TEXT before it parses the file,
    # and both commands below run on this host, so each referenced variable must
    # exist. The real private key must never be here (M5b), so each one gets
    # this dummy; CI resolves the real value. Any single-line value validates.
    PLACEHOLDER_VALUE = "kongsole-validation-placeholder".freeze
    ENV_REFERENCE = /\$\{\{ env "(DECK_[A-Z0-9_]+)" \}\}/
    MAX_MESSAGE = 2000
    NETWORK_KINDS = %i[dns refused timeout tls].freeze
    # decK can echo the header it was given; the credential never leaves.
    BASIC_CREDENTIAL = %r{Basic [A-Za-z0-9+/=]+}

    # `extra_paths` (R8.4): the env's other decK files in the same repo, read
    # alongside the rendered one as more positional state files -- decK merges
    # them. Kongsole never writes them.
    def self.validate(file_path, extra_paths: [])
      new.validate(file_path, extra_paths: extra_paths)
    end

    def self.diff(file_path, connection:, secret:, extra_paths: [])
      new.diff(file_path, connection: connection, secret: secret, extra_paths: extra_paths)
    end

    # R7 (CLAUDE.md rule 2's one exception): a snapshot of what Kong holds under
    # `select_tags`, read with the read-only credential and returned as text --
    # `-o -` writes it to stdout, so it never touches the disk before
    # Kong::ExportSanitizer has seen it. An untagged dump is the whole of Kong,
    # so it is refused here as well as in the sanitizer.
    def self.dump(connection:, secret:, select_tags:)
      new.dump(connection: connection, secret: secret, select_tags: select_tags)
    end

    def validate(file_path, extra_paths: [])
      _stdout, stderr, status = run([ "file", "validate", file_path.to_s, *extra_paths.map(&:to_s) ], [ file_path, *extra_paths ])
      raise Error, "deck file validate failed: #{clean(stderr)}" unless status.success?

      true
    end

    def diff(file_path, connection:, secret:, extra_paths: [])
      args = [
        "gateway", "diff", file_path.to_s, *extra_paths.map(&:to_s),
        "--kong-addr", connection.admin_url,
        "--headers", "Authorization:#{basic_auth(connection.auth_username, secret)}",
        "--json-output"
      ]
      stdout, stderr, status = run(args, [ file_path, *extra_paths ])
      raise failure("deck gateway diff failed", stderr) unless status.success?

      parse_diff(stdout)
    end

    def dump(connection:, secret:, select_tags:)
      tags = Array(select_tags)
      raise Error, "an export needs at least one select tag -- without one decK dumps the whole of Kong" if tags.empty?

      args = [
        "gateway", "dump", "-o", "-",
        *tags.flat_map { |tag| [ "--select-tag", tag.to_s ] },
        "--kong-addr", connection.admin_url,
        "--headers", "Authorization:#{basic_auth(connection.auth_username, secret)}"
      ]
      stdout, stderr, status = run(args, [])
      raise failure("deck gateway dump failed", stderr) unless status.success?

      stdout
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

    def run(args, file_paths)
      Open3.capture3(placeholder_env(file_paths), bin, *args)
    rescue Errno::ENOENT
      raise Error, "decK is not installed here: the deck binary (#{bin}) wasn't found -- install decK or point DECK_BIN at it"
    end

    # An unreachable Kong gets its network kind, so the explanation can say
    # which network problem it is (Kong::ErrorExplanation).
    def failure(prefix, stderr)
      message = "#{prefix}: #{clean(stderr)}"
      kind = Kong::NetworkFailure.classify_text(stderr)
      NETWORK_KINDS.include?(kind) ? Unreachable.new(message, kind: kind) : Error.new(message)
    end

    # Every file decK reads (the rendered one and the env's extra files) may
    # reference a DECK_ variable; each needs its dummy.
    def placeholder_env(file_paths)
      names = Array(file_paths).flat_map do |path|
        File.exist?(path) ? File.read(path).scan(ENV_REFERENCE).flatten : []
      end
      names.uniq.to_h { |name| [ name, PLACEHOLDER_VALUE ] }
    end

    # decK's own message is what an operator needs; a pasted private key is
    # never allowed through (M5b), and a runaway message is cut.
    def clean(stderr)
      Kong::CertificateKeyPolicy.scrub(stderr).gsub(BASIC_CREDENTIAL, "Basic [credential removed]").strip.truncate(MAX_MESSAGE)
    end

    def basic_auth(username, secret)
      "Basic #{Base64.strict_encode64("#{username}:#{secret}")}"
    end
  end
end
