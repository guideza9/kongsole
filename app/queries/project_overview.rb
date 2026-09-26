# R5.1: what a project is made of, per env, from this machine's read-model --
# never from Kong (the page opens without logging in, off the project's
# network). Two grouped queries whatever the number of envs.
class ProjectOverview
  COUNTED = %w[service route plugin consumer upstream certificate].freeze
  Row = Struct.new(:env, :connection, :status, :last_connected_at, :synced_at, :counts, keyword_init: true)

  def initialize(project)
    @project = project
  end

  def rows
    envs = @project.project_envs.includes(:kong_connection).to_a
    ids = envs.filter_map { _1.kong_connection&.id }
    counts = KongEntity.active.where(kong_connection_id: ids, entity_type: COUNTED).group(:kong_connection_id, :entity_type).count
    # kong_connections.last_synced_at is never written; the rows say when they were synced.
    synced = KongEntity.where(kong_connection_id: ids).group(:kong_connection_id).maximum(:synced_at)

    envs.map do |env|
      connection = env.kong_connection
      Row.new(env: env, connection: connection, status: connection&.last_status,
        last_connected_at: connection&.last_connected_at, synced_at: connection && synced[connection.id],
        counts: COUNTED.index_with { |type| connection ? counts.fetch([ connection.id, type ], 0) : 0 })
    end
  end
end
