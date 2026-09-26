module Kong
  # R4: the other envs of this connection's project whose cached schema for a
  # plugin differs from this connection's -- usually a different Kong
  # version, so a config that works here may not work there. Only what is
  # already in Kong::SchemaCache is compared: no other env is called (it may
  # sit on another network), and an env not yet cached says nothing.
  class SchemaMismatch
    def self.for(connection:, plugin_name:)
      own = KongSchema.digest_for(connection: connection, kind: "plugin", name: plugin_name)
      return [] if own.nil? || connection.project_env.nil?

      KongSchema.joins(kong_connection: :project_env)
        .where(kind: "plugin", name: plugin_name, project_envs: { project_id: connection.project_env.project_id })
        .where.not(kong_connection_id: connection.id)
        .where.not(digest: own)
        .order("project_envs.position")
        .pluck("project_envs.name", :kong_version)
        .map { |env, version| { env: env, kong_version: version } }
    end
  end
end
