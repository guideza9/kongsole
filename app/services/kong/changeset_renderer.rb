module Kong
  # R8.4: renders a whole changeset into the env's decK file, from the latest
  # git, the way one PR-mode plan used to be rendered (docs/DESIGN.md section
  # 6): every item in its order onto one parsed document, parents created in
  # the same changeset found through Kong::ChangesetResolver.
  #
  # `preview` does all of it except commit and push -- the YAML diff, decK's
  # own validate and diff (read-only credential), and the CI gate -- and always
  # leaves the working copy clean. `render!` is the shared core the submitter
  # (R8.6) commits from.
  class ChangesetRenderer
    Preview = Struct.new(:yaml_diff, :deck_diff, :gate, :drift, :error, :explanation, keyword_init: true)

    def initialize(changeset:, secret:)
      @changeset = changeset
      @connection = changeset.kong_connection
      @secret = secret
    end

    def preview
      git = nil
      git = Kong::GitClient.new(connection: @connection).pull!
      rendered = render!(git)
      git.write_file(@connection.git_path, rendered)
      yaml_diff = git.diff(@connection.git_path)

      file = git.working_dir.join(@connection.git_path)
      extra = extra_paths(git)
      Kong::DeckCli.validate(file, extra_paths: extra)
      deck_diff = Kong::DeckCli.diff(file, connection: @connection, secret: @secret, extra_paths: extra)

      Preview.new(yaml_diff: yaml_diff, deck_diff: deck_diff, gate: gate_for(deck_diff))
    rescue Kong::GitClient::Error, Kong::DeckCli::Error, Kong::Client::Error => e
      Preview.new(yaml_diff: yaml_diff, error: self.class.scrub(e.message), explanation: explanation_for(e))
    rescue Kong::ChangeGuardrails::Violation, NotImplementedError => e
      Preview.new(yaml_diff: yaml_diff, error: self.class.scrub(e.message))
    ensure
      git&.discard!
    end

    # The file as it will be pushed: every item, in order, onto the latest
    # git's copy, refusing anything that could not be reproduced byte-for-byte.
    def render!(git)
      items = @changeset.items.to_a
      items.each { |plan| Kong::DeckRenderer.assert_supported!(plan.entity_type) }
      require_select_tags!

      text = read_yaml(git)
      Kong::DeckDocument.verify_input!(text)
      doc = Kong::DeckDocument.parse(text, select_tags: @connection.select_tags)
      resolver = Kong::ChangesetResolver.new(@changeset)
      items.each { |plan| Kong::DeckRenderer.apply_change(doc, plan, resolver: resolver) }
      rendered = Kong::DeckDocument.serialize(doc)
      verify_round_trip!(rendered)
      rendered
    end

    def gate_for(deck_diff)
      Kong::CiGate.check(deck_diff: deck_diff, admin_path_names: admin_path_names,
        delete_threshold: @connection.project&.delete_threshold)
    end

    def extra_paths(git)
      Array(@connection.project_env&.deck_extra_paths).map { |path| git.working_dir.join(path).to_s }
    end

    # What leaves this class to be stored or shown: never a private key, never
    # a credential in a git remote URL (git echoes the remote it was given).
    URL_CREDENTIAL = %r{://[^/\s@]+@}
    MESSAGE_LIMIT = 2000

    def self.scrub(text)
      Kong::CertificateKeyPolicy.scrub(text.to_s).gsub(URL_CREDENTIAL, "://").truncate(MESSAGE_LIMIT)
    end

    private

    def admin_path_names
      KongEntity.where(kong_connection: @connection, is_admin_path: true).pluck(:name)
    end

    # A preview that could not reach git, decK's Kong or Kong gets the same
    # cause-and-next-step the rest of the console gives, with the project's
    # network note. A decK failure that is not about the network (a file decK
    # rejects) is shown as decK's own words only.
    def explanation_for(error)
      return nil if error.is_a?(Kong::DeckCli::Error) && !network_failure?(error.message)

      Kong::ErrorExplanation.for(error, network_note: @connection.project&.network_note)
    end

    def network_failure?(text)
      Kong::GitClient::NETWORK_KINDS.include?(Kong::NetworkFailure.classify_text(text))
    end

    # decK reads an empty `select_tags` as "no filter": `deck gateway sync` would
    # then treat the whole workspace as managed and delete everything the file
    # does not list (CLAUDE.md rule 2).
    def require_select_tags!
      return if Array(@connection.select_tags).map(&:to_s).reject(&:blank?).any?

      raise Kong::ChangeGuardrails::Violation,
        "this connection has no select_tags -- decK would sync the whole workspace and delete everything absent from " \
        "the config file; set select_tags on the env first"
    end

    def read_yaml(git)
      path = git.working_dir.join(@connection.git_path)
      File.exist?(path) ? File.read(path) : nil
    end

    def verify_round_trip!(rendered)
      Kong::DeckDocument.verify_input!(rendered)
    rescue Kong::DeckDocument::Unparseable => e
      raise Kong::ChangeGuardrails::Violation,
        "rendered YAML did not round-trip byte-for-byte (#{e.message}) -- refusing to push a diff that would be noisy to review"
    end
  end
end
