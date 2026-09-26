module Kong
  # R5.3: the plugins a traced request would run, in Kong's order (R5 spec
  # §4.3). Of several instances of one plugin, Kong runs the most specific
  # enabled one: route+service > route > service > global. Consumer-scoped
  # instances depend on who calls, which a trace does not know, so they are
  # listed apart.
  module PluginChain
    Step = Struct.new(:plugin, :scope, :priority, :enabled, :overrides, :effect, :consumer, keyword_init: true)
    SPECIFIC_FIRST = %w[route+service route service global].freeze

    module_function

    def for(connection:, route:, service:)
      priorities = connection.plugins_available.fetch("available_on_server", {})
      priorities = {} unless priorities.is_a?(Hash)
      general = Hash.new { |hash, name| hash[name] = [] }
      consumer_steps = []

      KongEntity.active.where(kong_connection: connection, entity_type: "plugin").find_each do |plugin|
        ids = %w[service route consumer].to_h { [ _1, plugin.data.dig(_1, "id") ] }
        next if ids["service"] && ids["service"] != service&.kong_id
        next if ids["route"] && ids["route"] != route&.kong_id

        priority = priorities.dig(plugin.name, "priority")
        if ids["consumer"]
          consumer_steps << step(plugin, "consumer", priority, [], consumer_name(connection, ids["consumer"]))
        else
          general[plugin.name] << [ plugin, scope_of(ids), priority ]
        end
      end

      [ order(general.values.flat_map { resolve(_1) }), order(consumer_steps) ]
    end

    def resolve(instances)
      ordered = instances.sort_by { |_, scope, _| SPECIFIC_FIRST.index(scope) }
      running, *replaced = ordered.select { |plugin, _, _| plugin.enabled }
      steps = ordered.reject { |plugin, _, _| plugin.enabled }.map { |plugin, scope, priority| step(plugin, scope, priority, []) }
      steps << step(running[0], running[1], running[2], replaced.map { |_, scope, _| scope }) if running
      steps
    end

    def scope_of(ids)
      if ids["route"] && ids["service"] then "route+service"
      elsif ids["route"] then "route"
      elsif ids["service"] then "service"
      else "global"
      end
    end

    def step(plugin, scope, priority, overrides, consumer = nil)
      Step.new(plugin: plugin, scope: scope, priority: priority, enabled: plugin.enabled, overrides: overrides,
        effect: Kong::PluginEffects.for(plugin.name, config: plugin.data["config"] || {}), consumer: consumer)
    end

    def order(steps)
      steps.sort_by { [ _1.priority ? -_1.priority : Float::INFINITY, _1.plugin.name.to_s ] }
    end

    def consumer_name(connection, kong_id)
      KongEntity.active.find_by(kong_connection: connection, entity_type: "consumer", kong_id: kong_id)&.name || kong_id.to_s[0, 8]
    end
  end
end
