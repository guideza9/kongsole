module Kong
  # R1.2: connections saved before projects existed each get their own env in
  # project `default` -- env name = the old connection name, so two
  # connections that shared an env (dev-readwrite / dev-readonly) do not
  # collide. Rank, apply_mode and git settings come from the connection; the
  # credential is not touched.
  #
  # Also builds (without saving) the env for a connection that arrives with
  # none -- the flat connections.yml list and the connection form until they
  # learn about projects (R1.4, R1.5).
  class LegacyProjectBackfill
    PROJECT_KEY = "default"
    PROJECT_NAME = "Default"
    GIT_FIELDS = %i[git_repo git_branch git_web_url].freeze

    class ConflictingRepos < StandardError; end

    def self.call
      new.call
    end

    def self.build_env_for(connection)
      new.build_env_for(connection)
    end

    def call
      legacy = KongConnection.where(project_env_id: nil).order(:rank, :name).to_a
      return if legacy.empty?

      ApplicationRecord.transaction do
        project = default_project
        adopt_git_settings(project, legacy)
        project.save!
        legacy.each do |connection|
          env = orphan_env(project, connection) || build_env(project, connection)
          env.save!
          # update_columns: the row predates the validations of this release;
          # only the fields the env now owns change.
          connection.update_columns(project_env_id: env.id, name: env.qualified_name, env: env.name, rank: env.rank)
        end
      end
    end

    def build_env_for(connection)
      project = default_project
      adopt_git_settings(project, [ connection ]) if GIT_FIELDS.all? { |f| project.public_send(f).blank? }
      build_env(project, connection)
    end

    private

    def default_project
      Project.find_or_initialize_by(key: PROJECT_KEY) do |project|
        project.name = PROJECT_NAME
        project.source = "local"
      end
    end

    # One repo per project (roadmap Q6). Only PR connections push, so only
    # their settings count; two different repos cannot become one project
    # without a person deciding which is right.
    def adopt_git_settings(project, connections)
      pr = connections.select { |c| c.apply_mode == "pr" }
      repos = pr.map(&:git_repo).compact_blank.uniq
      if repos.size > 1
        raise ConflictingRepos, "PR connections #{pr.map(&:name).join(', ')} push to different repos " \
          "(#{repos.join(', ')}); split them into projects in config/connections.yml before migrating"
      end

      GIT_FIELDS.each do |field|
        value = pr.map { |c| c.public_send(field) }.compact_blank.first
        project.public_send("#{field}=", value) if value && project.public_send(field).blank?
      end
    end

    # A rollback of the migration drops the link but keeps the renamed rows
    # (default/<env>) and their envs; migrating again reattaches each row to
    # its own env instead of making a second one.
    def orphan_env(project, connection)
      prefix = "#{PROJECT_KEY}/"
      return nil unless project.persisted? && connection.name.to_s.start_with?(prefix)

      env = project.project_envs.find_by(name: connection.name.delete_prefix(prefix))
      env if env && env.kong_connection.nil?
    end

    def build_env(project, connection)
      name = free_env_name(project, connection.name)
      project.project_envs.build(
        name: name,
        position: next_position(project),
        rank: ProjectEnv::KNOWN_RANKS.fetch(connection.env.to_s) { connection.rank },
        apply_mode: connection.apply_mode,
        color_tag: connection.color_tag,
        # PR mode could only come from connections.yml, so a PR env is a registry env.
        source: connection.apply_mode == "pr" ? "registry" : "local",
        git_path: connection.git_path,
        select_tags: Array(connection.select_tags)
      )
    end

    def free_env_name(project, connection_name)
      base = connection_name.to_s.parameterize.tr("_", "-").sub(/\A[^a-z0-9]+/, "")[0, 36].presence || "env"
      taken = project.persisted? ? project.project_envs.pluck(:name) : []
      taken += project.project_envs.map(&:name)
      candidate = base
      suffix = 1
      candidate = "#{base}-#{suffix += 1}" while taken.include?(candidate)
      candidate
    end

    def next_position(project)
      persisted = project.persisted? ? project.project_envs.maximum(:position).to_i : 0
      [ persisted, *project.project_envs.map(&:position).compact ].max + 1
    end
  end
end
