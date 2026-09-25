# R1: rank, apply_mode and git settings belong to the connection's env (and
# git settings to its project); the connection copies them on save. Specs
# that change policy after creating a connection go through here.
module EnvPolicyHelper
  PROJECT_FIELDS = %i[git_repo git_branch git_web_url].freeze

  def set_env_policy(connection, **attrs)
    project_attrs = attrs.extract!(*PROJECT_FIELDS)
    connection.project.update!(project_attrs) if project_attrs.any?
    if attrs.any?
      attrs[:source] = "registry" if attrs[:apply_mode] == "pr" # PR mode only comes from connections.yml
      connection.project_env.update!(attrs)
    end
    connection.save!
    connection
  end
end
