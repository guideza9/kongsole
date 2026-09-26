require "rails_helper"

RSpec.describe Kong::PluginSecretPolicy do
  let(:paths) { [ %w[config api_key] ] }

  it "refuses a plaintext secret in PR mode without echoing it" do
    expect { described_class.check!({ "config" => { "api_key" => "sk_live_123" } }, secret_paths: paths, apply_mode: "pr") }
      .to raise_error(Kong::ChangePlanner::InvalidChange) { |e| expect(e.message).not_to include("sk_live_123") }
  end

  it "accepts a vault reference or a decK env placeholder in PR mode" do
    [ "{vault://env/payments-api-key}", '${{ env "DECK_PAYMENTS_API_KEY" }}' ].each do |value|
      expect { described_class.check!({ "config" => { "api_key" => value } }, secret_paths: paths, apply_mode: "pr") }.not_to raise_error
    end
  end

  it "accepts plaintext in direct mode (Kong stores it; the read-model never does)" do
    expect { described_class.check!({ "config" => { "api_key" => "x" } }, secret_paths: paths, apply_mode: "direct") }.not_to raise_error
  end

  it "names the field and shows a reference to use instead" do
    expect { described_class.check!({ "config" => { "api_key" => "x" } }, secret_paths: paths, apply_mode: "pr") }
      .to raise_error(Kong::ChangePlanner::InvalidChange, %r{config\.api_key.*\{vault://env/})
  end

  # http-log's headers: the schema marks the map's values, so every value in
  # it must be a reference -- an Authorization header is the usual one.
  it "checks every value of a marked map, without echoing any" do
    headers = [ %w[config headers] ]
    expect { described_class.check!({ "config" => { "headers" => { "Authorization" => "Bearer abc" } } }, secret_paths: headers, apply_mode: "pr") }
      .to raise_error(Kong::ChangePlanner::InvalidChange) { |e| expect(e.message).not_to include("Bearer abc") }
    expect { described_class.check!({ "config" => { "headers" => { "Authorization" => "{vault://env/log-auth}" } } }, secret_paths: headers, apply_mode: "pr") }
      .not_to raise_error
  end

  it "lets an absent or kept-back secret through" do
    expect { described_class.check!({ "config" => {} }, secret_paths: paths, apply_mode: "pr") }.not_to raise_error
    expect { described_class.check!({ "config" => { "api_key" => Kong::Redactor::MARK } }, secret_paths: paths, apply_mode: "pr") }.not_to raise_error
  end

  it "fails closed in PR mode when the plugin's schema could not be read" do
    expect { described_class.check!({ "config" => {} }, secret_paths: nil, apply_mode: "pr") }
      .to raise_error(Kong::ChangePlanner::InvalidChange, /schema/)
  end
end
