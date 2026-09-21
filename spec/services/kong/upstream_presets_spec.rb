require "rails_helper"

RSpec.describe Kong::UpstreamPresets do
  describe ".seed" do
    it "is a minimal upstream with no health checks by default" do
      seed = described_class.seed(nil)

      expect(seed).to eq({ "name" => "", "algorithm" => "round-robin", "tags" => [] })
    end

    it "adds an active HTTP health check for the active_http preset, keeping the defaults" do
      seed = described_class.seed("active_http")

      expect(seed).to include("name" => "", "algorithm" => "round-robin")
      expect(seed.dig("healthchecks", "active", "type")).to eq("http")
      expect(seed.dig("healthchecks", "active", "http_path")).to eq("/health")
      expect(seed.dig("healthchecks", "active", "healthy", "interval")).to eq(5)
      expect(seed.dig("healthchecks", "active", "unhealthy", "http_failures")).to eq(2)
    end

    it "falls back to the defaults for an unknown preset instead of raising" do
      expect(described_class.seed("nope")).to eq(described_class.seed(nil))
    end

    it "returns a fresh copy each time, so a caller mutating it can't poison the next request" do
      described_class.seed("active_http")["healthchecks"]["active"]["http_path"] = "/mutated"

      expect(described_class.seed("active_http").dig("healthchecks", "active", "http_path")).to eq("/health")
    end
  end

  describe ".choices" do
    it "lists the selectable presets as [key, label] pairs, defaults first" do
      choices = described_class.choices

      expect(choices.first).to eq([ nil, "Defaults" ])
      expect(choices).to include([ "active_http", "Active HTTP health check" ])
    end

    it "never puts the literal field name in a label, so the default page stays free of it" do
      expect(described_class.choices.map(&:last).join).not_to include("healthchecks")
    end
  end
end
