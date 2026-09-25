module Kong
  # Loads config/connections.yml -- the team's shared, git-tracked connection
  # *registry* -- and upserts KongConnection rows from it. No credential ever
  # lives in this file or is touched by this loader (docs/DESIGN.md section 3):
  # a new teammate pulls the repo, sees every connection already defined, and
  # only has to supply their own credential through the login flow.
  class ConnectionsConfigLoader
    DEFAULT_PATH = Rails.root.join("config/connections.yml")

    def self.call(path: DEFAULT_PATH)
      new(path).call
    end

    def initialize(path)
      @path = path
    end

    def call
      return [] unless File.exist?(@path)

      entries.map { |entry| upsert(entry) }
    end

    private

    def entries
      raw = ERB.new(File.read(@path)).result
      YAML.safe_load(raw, permitted_classes: [ Symbol ], aliases: true) || []
    end

    def upsert(entry)
      attrs = entry.symbolize_keys
      name = attrs.fetch(:name)
      # R1.2: a flat entry lives in project `default` as default/<name>.
      connection = KongConnection.find_by(name: "#{LegacyProjectBackfill::PROJECT_KEY}/#{name}") ||
        KongConnection.find_or_initialize_by(name: name)
      connection.assign_attributes(
        env: attrs[:env],
        admin_url: attrs[:admin_url],
        auth_type: attrs[:auth_type] || "basic",
        # R1.3: no apply_mode means not set (read-only), never direct.
        apply_mode: attrs[:apply_mode],
        verify_ssl: attrs.fetch(:verify_ssl, true),
        # docs/DESIGN.md section 3: the http:// escape hatch may only ever be
        # set from this file, never from the web UI (see ConnectionsController).
        allow_insecure_http: attrs.fetch(:insecure_http, false),
        ca_bundle_path: attrs[:ca_bundle_path],
        git_repo: attrs[:git_repo],
        git_branch: attrs[:git_branch],
        git_path: attrs[:git_path],
        git_web_url: attrs[:git_web_url],
        select_tags: Array(attrs[:select_tags]),
        shared_usernames: Array(attrs[:shared_usernames])
      )
      connection.color_tag = attrs[:color_tag] if attrs[:color_tag].present?
      connection.save!
      connection
    end
  end
end
