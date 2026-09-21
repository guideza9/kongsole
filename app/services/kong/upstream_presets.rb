module Kong
  # Starting points for the "New upstream" JSON editor -- docs/DESIGN.md
  # section 15 M5. An upstream's `healthchecks` block is deeply nested (active
  # and passive, each with healthy and unhealthy branches), so instead of a
  # bespoke form -- which would duplicate Kong's own schema rules and drift
  # from them -- the editor is seeded from a preset and Kong::ChangePlanner
  # validates the result against `POST /schemas/upstreams/validate`.
  module UpstreamPresets
    DEFAULTS = { "name" => "", "algorithm" => "round-robin", "tags" => [] }.freeze

    PRESETS = {
      "active_http" => {
        label: "Active HTTP health check",
        body: {
          "healthchecks" => {
            "active" => {
              "type" => "http",
              "http_path" => "/health",
              "healthy" => { "interval" => 5, "successes" => 2 },
              "unhealthy" => { "interval" => 5, "http_failures" => 2, "timeouts" => 2 }
            }
          }
        }
      }
    }.freeze

    # A fresh deep copy on every call, so a caller mutating it can't change
    # what the next request is seeded with. An unknown key is the defaults,
    # not an error -- the preset arrives from a query string.
    def self.seed(preset_key)
      body = PRESETS.dig(preset_key.to_s, :body) || {}
      DEFAULTS.merge(body).deep_dup
    end

    # [key, label] pairs for the "Start from" links; nil is the defaults.
    def self.choices
      [ [ nil, "Defaults" ] ] + PRESETS.map { |key, preset| [ key, preset[:label] ] }
    end
  end
end
