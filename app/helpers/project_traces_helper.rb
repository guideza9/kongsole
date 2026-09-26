# R5.8: how the request tracer words and marks what Kong::RequestTrace found.
# Formatting only -- which route, which plugins and what the service receives
# are decided in app/services/kong/{route_matcher,plugin_chain,
# forwarded_request}.rb.
module ProjectTracesHelper
  # The scope mark (entities/_scope) for one step of the plugin chain: the
  # route and service are the traced ones, so their names are at hand.
  def trace_scope(step, match)
    case step.scope
    when "global" then { kind: "global" }
    when "route" then { kind: "route", name: match.route.name }
    when "service" then { kind: "service", name: match.service&.name }
    when "route+service" then { kind: "route + service", name: match.route.name }
    else { kind: "consumer", name: step.consumer }
    end
  end

  # What an enabled plugin may do before the request reaches the service,
  # for stop 3's note; nil when it does neither (see Kong::PluginEffects).
  def trace_effect(step)
    effect = step.effect
    return nil unless step.enabled && effect && effect.kind != :answers

    t("hints.pages.project_trace.effects.#{effect.kind}", status: effect.status)
  end

  # "60 s" for Kong's millisecond timeouts; whole seconds read at a glance.
  def trace_seconds(milliseconds)
    return nil if milliseconds.blank?

    seconds = milliseconds.to_i / 1000.0
    "#{seconds == seconds.round ? seconds.round : seconds.round(1)} s"
  end
end
