require "rails_helper"

RSpec.describe Kong::PluginEffects do
  it "knows which bundled plugins may stop a request, and with what status" do
    expect(described_class.for("key-auth")).to have_attributes(kind: :may_stop, status: 401)
    expect(described_class.for("acl")).to have_attributes(kind: :may_stop, status: 403)
    expect(described_class.for("rate-limiting")).to have_attributes(kind: :may_stop, status: 429)
    expect(described_class.for("request-size-limiting")).to have_attributes(kind: :may_stop, status: 413)
  end

  it "knows which may change it or answer from cache" do
    expect(described_class.for("request-transformer").kind).to eq(:may_change)
    expect(described_class.for("pre-function").kind).to eq(:may_change)
    expect(described_class.for("proxy-cache").kind).to eq(:may_answer)
  end

  it "says request-termination answers, unless a trigger limits it (Review Focus 4)" do
    expect(described_class.for("request-termination", config: { "trigger" => nil }).kind).to eq(:answers)
    expect(described_class.for("request-termination", config: { "trigger" => "x-maintenance" }).kind).to eq(:may_answer)
  end

  it "has nothing to say about a bundled plugin that does neither" do
    expect(described_class.for("prometheus")).to be_nil
    expect(described_class.for("cors")).to be_nil
  end

  it "always names a custom plugin, whose behaviour it cannot know" do
    expect(described_class.for("team-auth").kind).to eq(:unknown)
  end
end
