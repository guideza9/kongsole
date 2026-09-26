module Kong
  # R5.2: which route Kong would pick for a request, from the read-model only
  # (R5 spec §4.2). An approximation of Kong 3.7's traditional_compatible
  # router: hosts, methods and paths; no headers, SNI or expressions routes.
  # The order is pinned by spec/fixtures/kong_router/ordering.json, recorded
  # from compose Kong (R5.0) -- when the two disagree, Kong is right.
  module RouteMatcher
    Result = Struct.new(:route, :service, :matched_on, :losers, :skipped, keyword_init: true)
    Candidate = Struct.new(:route, :conditions, :host_kind, :path, :regex, :regex_priority, :matched, keyword_init: true)

    HTTP = %w[http https].freeze
    CONDITION_FIELDS = %w[hosts methods paths headers snis].freeze
    HOST_RANK = { exact: 0, wildcard: 1, any: 2 }.freeze
    REGEX_TIMEOUT = 0.1
    UNREADABLE = "uses regex syntax Kongsole can't read".freeze

    module_function

    def call(connection:, host:, path:, method:)
      host = host.to_s.strip.downcase.sub(/:\d+\z/, "")
      method = method.to_s.upcase
      skipped = []

      candidates = KongEntity.active.where(kong_connection: connection, entity_type: "route").to_a.filter_map do |route|
        candidate_for(route, host, path, method, skipped)
      end
      winner, *others = candidates.sort_by { sort_key(_1) }
      return Result.new(route: nil, service: nil, matched_on: nil, losers: [], skipped: skipped) unless winner

      Result.new(route: winner.route, service: service_of(connection, winner.route),
        matched_on: { host: (host if winner.host_kind != :any), method: (method if Array(winner.route.data["methods"]).any?),
                      path: winner.path, regex: winner.regex, matched: winner.matched },
        losers: others.map { { route: _1.route, reason: loss_reason(winner, _1) } }, skipped: skipped)
    end

    def candidate_for(route, host, path, method, skipped)
      data = route.data
      if data["expression"].present?
        skipped << { route: route, reason: "an expressions route -- the tracer reads traditional routes only" }
        return nil
      end
      protocols = Array(data["protocols"])
      return nil if protocols.any? && (protocols & HTTP).empty?

      host_kind = host_kind(Array(data["hosts"]), host) or return nil
      methods = Array(data["methods"])
      return nil unless methods.empty? || methods.include?(method)

      hit = path_hit(route, Array(data["paths"]), path, skipped) or return nil
      Candidate.new(route: route, conditions: CONDITION_FIELDS.count { data[_1].present? }, host_kind: host_kind,
        path: hit[:path], regex: hit[:regex], regex_priority: data["regex_priority"].to_i, matched: hit[:matched])
    end

    def host_kind(hosts, host)
      return :any if hosts.empty?
      return :exact if hosts.any? { _1.downcase.sub(/:\d+\z/, "") == host }
      :wildcard if hosts.any? { wildcard_match?(_1.downcase, host) }
    end

    def wildcard_match?(pattern, host)
      if pattern.start_with?("*.") then host.end_with?(pattern.delete_prefix("*"))
      elsif pattern.end_with?(".*") then host.start_with?(pattern.delete_suffix("*"))
      else false
      end
    end

    # The route's best path for this request: a matching regex first (Kong
    # tries regex paths before prefixes), else the longest matching prefix.
    def path_hit(route, paths, path, skipped)
      return { path: nil, regex: false, matched: "" } if paths.empty?

      regex_hits, prefix_hits = [], []
      paths.each do |candidate|
        if candidate.start_with?("~")
          begin
            match = Regexp.new("\\A(?:#{candidate.delete_prefix('~')})", timeout: REGEX_TIMEOUT).match(path)
            regex_hits << { path: candidate, regex: true, matched: match[0] } if match
          rescue RegexpError, Regexp::TimeoutError
            skipped << { route: route, reason: UNREADABLE } unless skipped.any? { _1[:route] == route }
          end
        elsif path.start_with?(candidate)
          prefix_hits << { path: candidate, regex: false, matched: candidate }
        end
      end
      regex_hits.first || prefix_hits.max_by { _1[:path].length }
    end

    def sort_key(candidate)
      [ -candidate.conditions, HOST_RANK.fetch(candidate.host_kind), candidate.regex ? 0 : 1,
        -(candidate.regex ? candidate.regex_priority : 0), -(candidate.regex ? 0 : candidate.path.to_s.length),
        candidate.route.kong_created_at || Time.at(0) ]
    end

    LOSS_REASONS = [
      ->(winner, _) { "sets fewer conditions than #{winner.route.name}" },
      ->(_, _) { "a wildcard host loses to an exact one" },
      ->(_, _) { "a prefix path is tried after regex paths" },
      ->(winner, loser) { "a lower regex_priority (#{loser.regex_priority} < #{winner.regex_priority})" },
      ->(winner, _) { "a shorter prefix than #{winner.path}" },
      ->(winner, _) { "created after #{winner.route.name}" }
    ].freeze

    def loss_reason(winner, loser)
      index = sort_key(winner).zip(sort_key(loser)).index { |a, b| a != b } || LOSS_REASONS.size - 1
      LOSS_REASONS.fetch(index).call(winner, loser)
    end

    def service_of(connection, route)
      return nil unless route.parent_kong_id

      KongEntity.active.find_by(kong_connection: connection, entity_type: "service", kong_id: route.parent_kong_id)
    end
  end
end
