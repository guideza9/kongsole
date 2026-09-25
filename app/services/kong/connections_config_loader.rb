module Kong
  # Loads config/connections.yml -- the team's shared, git-tracked connection
  # *registry* -- and upserts projects, their envs and one connection per env
  # from it. No credential ever lives in this file or is touched by this
  # loader (docs/DESIGN.md section 3): a new teammate pulls the repo, sees
  # every connection already defined, and only has to supply their own
  # credential through the login flow.
  #
  # R1.4: the file lists projects, each with its envs in the project's own
  # order. Everything it loads is `registry` -- edited in this file, never in
  # the UI -- and it is the only place an env can be PR mode. The legacy flat
  # list still loads, into project `default`.
  #
  # The whole file loads or none of it does: one bad env (an "other" name
  # without a rank, say) raises InvalidRegistry naming it, and nothing is
  # saved. An env that has left the file is kept, not deleted -- `warnings`
  # names it so a person decides.
  class ConnectionsConfigLoader
    DEFAULT_PATH = Rails.root.join("config/connections.yml")

    class InvalidRegistry < StandardError; end

    attr_reader :warnings

    def self.call(path: DEFAULT_PATH)
      new(path).call
    end

    def initialize(path = DEFAULT_PATH)
      @path = path
      @warnings = []
    end

    def call
      return [] unless File.exist?(@path)

      data = parse
      connections = ApplicationRecord.transaction do
        data.is_a?(Hash) ? load_projects(Array(data["projects"])) : load_legacy(Array(data))
      end
      @warnings = stale_warnings(connections)
      connections
    rescue ActiveRecord::RecordInvalid => e
      raise InvalidRegistry, "#{label_for(e.record)}: #{e.record.errors.map { |err| "#{err.attribute} #{err.message}" }.join(', ')}"
    end

    private

    def parse
      raw = ERB.new(File.read(@path)).result
      YAML.safe_load(raw, permitted_classes: [ Symbol ], aliases: true) || []
    end

    def load_projects(entries)
      entries.flat_map do |entry|
        entry = entry.stringify_keys
        project = Project.find_or_initialize_by(key: entry["key"].to_s.strip.downcase)
        project.assign_attributes(
          name: entry["name"].presence || entry["key"],
          source: "registry",
          git_repo: entry["git_repo"], git_branch: entry["git_branch"], git_web_url: entry["git_web_url"],
          network_note: entry["network_note"].presence # R1.11: which network reaches it
        )
        project.save!
        load_envs(project, Array(entry["envs"]))
      end
    end

    def load_envs(project, entries)
      # Positions are unique per project; park the current ones out of the way
      # so the file can reorder envs freely.
      project.project_envs.update_all("position = -position - 1000") if project.persisted?

      connections = entries.each_with_index.map do |entry, index|
        entry = entry.stringify_keys
        env = project.project_envs.find_or_initialize_by(name: entry["name"].to_s.strip.downcase)
        env.assign_attributes(env_attributes(entry).merge(position: index + 1))
        env.save!
        upsert_connection(env, entry)
      end

      # An env that left the file keeps its row, after the listed ones.
      project.project_envs.where("position < 0").order(:position).each_with_index do |env, i|
        env.update_columns(position: entries.size + i + 1)
      end
      connections
    end

    def env_attributes(entry)
      {
        rank: entry["rank"],
        apply_mode: entry["apply_mode"].presence, # R1.3: absent = not set, never direct
        color_tag: entry["color_tag"].presence,
        source: "registry",
        git_path: entry["git_path"],
        select_tags: Array(entry["select_tags"]),
        deck_extra_paths: Array(entry["deck_extra_paths"])
      }
    end

    # Only the machine-facing fields; there is no credential key to read.
    def upsert_connection(env, entry)
      connection = env.kong_connection || KongConnection.new(project_env: env)
      connection.project_env = env
      connection.assign_attributes(
        admin_url: entry["admin_url"],
        auth_type: entry["auth_type"] || "basic",
        verify_ssl: entry.fetch("verify_ssl", true),
        # docs/DESIGN.md section 3: the http:// escape hatch may only ever be
        # set from this file, never from the web UI (see ConnectionsController).
        allow_insecure_http: entry.fetch("insecure_http", false),
        ca_bundle_path: entry["ca_bundle_path"],
        shared_usernames: Array(entry["shared_usernames"])
      )
      connection.save!
      connection
    end

    # The flat list: each entry is its own env in project `default`, named
    # after the entry (see Kong::LegacyProjectBackfill), its rank from `env`.
    def load_legacy(entries)
      entries = entries.map(&:stringify_keys)
      project = Project.find_or_initialize_by(key: LegacyProjectBackfill::PROJECT_KEY)
      if project.new_record?
        project.assign_attributes(name: LegacyProjectBackfill::PROJECT_NAME, source: "registry")
      end
      pr = entries.select { |e| e["apply_mode"] == "pr" }
      %w[git_repo git_branch git_web_url].each do |field|
        value = pr.map { |e| e[field] }.compact_blank.first
        project.public_send("#{field}=", value) if value
      end
      project.save!

      entries.map do |entry|
        env = project.project_envs.find_or_initialize_by(name: entry["name"].to_s.parameterize.tr("_", "-"))
        env.position ||= project.project_envs.maximum(:position).to_i + 1
        env.assign_attributes(env_attributes(entry).merge(
          rank: ProjectEnv::KNOWN_RANKS.fetch(entry["env"].to_s) { entry["rank"] },
          color_tag: entry["color_tag"].presence || env.color_tag
        ))
        env.save!
        upsert_connection(env, entry)
      end
    end

    def stale_warnings(connections)
      loaded = connections.map(&:project_env_id)
      ProjectEnv.where(source: "registry").where.not(id: loaded).includes(:project).map do |env|
        "#{env.qualified_name} is no longer in #{File.basename(@path)} -- kept; remove it in Kongsole if it is gone for good"
      end
    end

    def label_for(record)
      case record
      when ProjectEnv then record.qualified_name
      when KongConnection then record.project_env&.qualified_name || record.name
      when Project then record.key
      else record.class.name
      end
    end
  end
end
