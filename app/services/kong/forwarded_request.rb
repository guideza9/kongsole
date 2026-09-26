module Kong
  # R5.4: what the service receives for a traced request (R5 spec §4.4),
  # split by who decides it: the route (what it strips, which Host header)
  # and the service (where it sends, what path it adds). Plugins are not
  # run; request-termination is the one case whose outcome is certain.
  # The path join is pinned by spec/fixtures/kong_router/join.json (R5.0).
  module ForwardedRequest
    Result = Struct.new(:route_effect, :service_effect, :answered_by, keyword_init: true)
    RouteEffect = Struct.new(:removed, :kept, :query, :host_header, :preserve_host, :strip_path, :path_handling, keyword_init: true)
    ServiceEffect = Struct.new(:url, :protocol, :host, :port, :added_path, :tls_verify, :upstream, :not_forwarded, :timeouts, :retries, keyword_init: true)
    Upstream = Struct.new(:name, :algorithm, :targets, :host_header, keyword_init: true)
    DEFAULT_PORTS = { "http" => 80, "https" => 443 }.freeze

    module_function

    def call(connection:, match:, host:, path:, query:, steps:)
      return nil unless match&.route

      data = match.route.data
      strip = data.fetch("strip_path", true) != false
      matched = match.matched_on[:matched].to_s
      removed = strip ? matched : ""
      kept = path.delete_prefix(removed)
      handling = data["path_handling"].presence || "v0"
      upstream = upstream_for(connection, match.service)

      route_effect = RouteEffect.new(removed: removed, kept: kept, query: query.presence,
        host_header: data["preserve_host"] ? host.to_s.downcase.sub(/:\d+\z/, "") : host_header(match.service, upstream),
        preserve_host: !!data["preserve_host"], strip_path: strip, path_handling: handling)

      Result.new(route_effect: route_effect, service_effect: service_effect(match.service, upstream, kept, handling, query),
        answered_by: answered_by(steps))
    end

    def service_effect(service, upstream, kept, handling, query)
      return nil unless service

      data = service.data
      protocol = data["protocol"].presence || "http"
      port = data["port"]
      authority = [ data["host"], (port unless port == DEFAULT_PORTS[protocol]) ].compact.join(":")
      url = "#{protocol}://#{authority}#{join(data['path'], kept, handling)}#{"?#{query}" if query.present?}"

      ServiceEffect.new(url: url, protocol: protocol, host: data["host"], port: port, added_path: data["path"].presence,
        tls_verify: data["tls_verify"], upstream: upstream,
        not_forwarded: (503 if upstream && upstream.targets.empty?),
        timeouts: { connect: data["connect_timeout"], read: data["read_timeout"], write: data["write_timeout"] },
        retries: data["retries"])
    end

    # One "/" between the service's path and what the route left; nothing
    # left -> the service's path, or "/". Kong's docs describe path_handling
    # v1 as joining without the slash, but Kong 3.7's traditional_compatible
    # router joins v1 exactly like v0 (join.json, recorded from compose in
    # R5.0), so `handling` does not change the result on this router.
    def join(base, rest, _handling)
      base = base.presence || "/"
      return base if rest.empty?

      "#{base.chomp('/')}/#{rest.delete_prefix('/')}"
    end

    def upstream_for(connection, service)
      return nil unless service

      upstream = KongEntity.active.find_by(kong_connection: connection, entity_type: "upstream", name: service.data["host"])
      return nil unless upstream

      targets = KongEntity.active.where(kong_connection: connection, entity_type: "target", parent_kong_id: upstream.kong_id)
        .select { _1.data["weight"].to_i.positive? }.map(&:name).sort
      Upstream.new(name: upstream.name, algorithm: upstream.data["algorithm"], targets: targets,
        host_header: upstream.data["host_header"].presence)
    end

    # The Host header Kong sends when preserve_host is off: the service's
    # host, with its port when that is not the protocol's default (compose
    # Kong sends "127.0.0.1:8000"), or an upstream's own host_header.
    def host_header(service, upstream)
      return nil unless service
      return upstream.host_header if upstream&.host_header

      data = service.data
      port = data["port"]
      port && port != DEFAULT_PORTS[data["protocol"].presence || "http"] ? "#{data['host']}:#{port}" : data["host"]
    end

    def answered_by(steps)
      step = steps.find { _1.enabled && _1.effect&.kind == :answers }
      step && { plugin: step.plugin, status: step.effect.status, message: step.plugin.data.dig("config", "message") }
    end
  end
end
