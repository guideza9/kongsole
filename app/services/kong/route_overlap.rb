module Kong
  # R2.3: which existing routes a new one would compete with for the same
  # requests (roadmap Q21). Two routes overlap when their hosts, methods and
  # paths all overlap -- an empty list on either side means "any". A regex
  # path is not second-guessed: the answer is :unknown ("can't tell").
  #
  # Reads the read-model and the open changeset only, never Kong: it runs on
  # every keystroke of the route form. A warning, never a block.
  module RouteOverlap
    REASON_ORDER = { exact: 0, prefix: 1, unknown: 2 }.freeze

    module_function

    # `exclude_plan_id`: the changeset item being reviewed, which would
    # otherwise overlap itself.
    def check(connection:, hosts:, paths:, methods:, changeset: nil, exclude_kong_id: nil, exclude_plan_id: nil)
      new_route = normalise(hosts, paths, methods)
      candidates(connection, changeset, exclude_kong_id, exclude_plan_id).filter_map do |route|
        next if route[:admin_path] && !names_admin_host?(new_route, route)

        reason = reason_for(new_route, route)
        reason && { route_name: route[:name], service_name: route[:service_name], reason: reason }
      end.sort_by { |hit| [ REASON_ORDER.fetch(hit[:reason]), hit[:route_name].to_s ] }
    end

    # The read-model's live routes, with what the open changeset already
    # changes in place of them: its creates are added, its updates replace
    # the route they change, its deletes take theirs away.
    def candidates(connection, changeset, exclude_kong_id, exclude_plan_id = nil)
      items = changeset ? changeset.items.where(entity_type: "route").where.not(id: exclude_plan_id).to_a : []
      replaced = items.filter_map(&:target_kong_id) + [ exclude_kong_id ].compact

      live = KongEntity.active.where(kong_connection: connection, entity_type: "route").where.not(kong_id: replaced).to_a
      names = service_names(connection, live.map(&:parent_kong_id) + items.map { |plan| plan.after.dig("service", "id") })

      from_kong = live.map do |entity|
        describe(entity.data, entity.name, names[entity.parent_kong_id]).merge(admin_path: entity.is_admin_path?)
      end
      from_changeset = items.reject(&:delete?).map do |plan|
        describe(plan.after, plan.after["name"], names[plan.after.dig("service", "id")])
      end
      from_kong + from_changeset
    end

    # The routes the console reaches Kong through answer only their own hosts;
    # a route that does not name one of those hosts is no competition for
    # them (host outranks every other match in Kong's router), and warning
    # about them on every host-less route would teach operators to ignore
    # the warning.
    def names_admin_host?(new_route, admin_route)
      new_route[:hosts].any? && hosts_overlap?(new_route[:hosts], admin_route[:hosts])
    end

    def describe(data, name, service_name)
      normalise(data["hosts"], data["paths"], data["methods"]).merge(name: name, service_name: service_name)
    end

    # Service names by kong id -- the read-model's, then the changeset's
    # provisional ones.
    def service_names(connection, ids)
      ids = ids.compact.uniq
      names = KongEntity.active.where(kong_connection: connection, entity_type: "service", kong_id: ids).pluck(:kong_id, :name).to_h
      ChangePlan.where(kong_connection: connection, provisional_kong_id: ids - names.keys).find_each { |plan| names[plan.provisional_kong_id] = plan.after["name"] }
      names
    end

    def normalise(hosts, paths, methods)
      {
        hosts: Array(hosts).map { |host| host.to_s.strip.downcase }.reject(&:empty?),
        paths: Array(paths).map { |path| path.to_s.strip }.reject(&:empty?),
        methods: Array(methods).map { |method| method.to_s.strip.upcase }.reject(&:empty?)
      }
    end

    def reason_for(one, other)
      return nil unless hosts_overlap?(one[:hosts], other[:hosts])
      return nil unless one[:methods].empty? || other[:methods].empty? || one[:methods].intersect?(other[:methods])

      paths_reason(one[:paths].presence || [ "/" ], other[:paths].presence || [ "/" ])
    end

    def paths_reason(ours, theirs)
      reasons = ours.product(theirs).filter_map { |a, b| path_reason(a, b) }
      reasons.min_by { |reason| REASON_ORDER.fetch(reason) }
    end

    # Kong matches a plain path as a string prefix ("/api" takes "/apis").
    def path_reason(a, b)
      return :unknown if a.start_with?("~") || b.start_with?("~")
      return :exact if a == b

      :prefix if a.start_with?(b) || b.start_with?(a)
    end

    def hosts_overlap?(ours, theirs)
      return true if ours.empty? || theirs.empty?

      ours.product(theirs).any? { |a, b| host_overlap?(a, b) }
    end

    def host_overlap?(a, b)
      host_a, port_a = a.split(":", 2)
      host_b, port_b = b.split(":", 2)
      return false if port_a && port_b && port_a != port_b

      host_a == host_b || wildcard_match?(host_a, host_b) || wildcard_match?(host_b, host_a) ||
        (wildcard?(host_a) && wildcard?(host_b) && wildcards_meet?(host_a, host_b))
    end

    def wildcard?(host) = host.start_with?("*.") || host.end_with?(".*")

    # `*.example.com` takes one or more labels in front ("api.example.com",
    # "a.b.example.com", never "example.com"); `example.*` takes one label
    # at the end.
    def wildcard_match?(pattern, host)
      return false if wildcard?(host)

      if pattern.start_with?("*.")
        suffix = pattern.delete_prefix("*")
        host.end_with?(suffix) && host.length > suffix.length
      elsif pattern.end_with?(".*")
        prefix = pattern.delete_suffix("*")
        host.start_with?(prefix) && host.length > prefix.length && !host.delete_prefix(prefix).include?(".")
      else
        false
      end
    end

    # Two wildcards: the same kind meet when one's fixed part contains the
    # other's; a leading and a trailing wildcard can always name one host
    # between them ("api.*" and "*.example.com" both take "api.example.com").
    def wildcards_meet?(a, b)
      return true if a.start_with?("*.") != b.start_with?("*.")

      if a.start_with?("*.")
        a.delete_prefix("*").end_with?(b.delete_prefix("*")) || b.delete_prefix("*").end_with?(a.delete_prefix("*"))
      else
        a.delete_suffix("*").start_with?(b.delete_suffix("*")) || b.delete_suffix("*").start_with?(a.delete_suffix("*"))
      end
    end
  end
end
