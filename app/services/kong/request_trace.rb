module Kong
  # R5.6: one traced request, stop by stop (R5 spec §4) -- route, plugins,
  # what the service receives -- all from the read-model.
  module RequestTrace
    Trace = Struct.new(:connection, :synced_at, :match, :steps, :consumer_steps, :forwarded, keyword_init: true)

    def self.call(connection:, http_method:, host:, path:, query:)
      match = Kong::RouteMatcher.call(connection: connection, host: host, path: path, method: http_method)
      steps, consumer_steps = match.route ? Kong::PluginChain.for(connection: connection, route: match.route, service: match.service) : [ [], [] ]
      Trace.new(connection: connection, synced_at: KongEntity.where(kong_connection: connection).maximum(:synced_at),
        match: match, steps: steps, consumer_steps: consumer_steps,
        forwarded: Kong::ForwardedRequest.call(connection: connection, match: match, host: host, path: path, query: query, steps: steps))
    end
  end
end
