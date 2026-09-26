require "rails_helper"

RSpec.describe Kong::PlanSecretSeal do
  let(:paths) { [ %w[config aws_secret] ] }
  let(:after) { { "name" => "aws-lambda", "config" => { "aws_secret" => "sk_PLAIN", "function_name" => "f" } } }

  def split(**overrides)
    described_class.split(entity_type: "plugin", apply_mode: "direct", after: after, diff: { "operation" => "create" },
      secret_paths: paths, **overrides)
  end

  it "redacts a direct-mode plugin's secret and seals the real value" do
    result = split
    expect(result[:after]["config"]).to eq("aws_secret" => Kong::Redactor::MARK, "function_name" => "f")
    expect(result[:sealed]["after"]["config"]["aws_secret"]).to eq("sk_PLAIN")
    expect(result[:diff]).to eq("operation" => "create")
  end

  it "seals nothing when there is nothing secret to hide" do
    result = split(after: { "name" => "aws-lambda", "config" => { "aws_secret" => "{vault://env/lambda-secret}" } })
    expect(result[:sealed]).to be_nil
    expect(result[:after]["config"]["aws_secret"]).to eq("{vault://env/lambda-secret}")
  end

  it "leaves PR mode and other entity types alone" do
    expect(split(apply_mode: "pr")).to eq(after: after, diff: { "operation" => "create" }, sealed: nil)
    expect(split(entity_type: "service")[:sealed]).to be_nil
  end

  it "redacts both sides of an update's diff and seals the real one" do
    diff = { "config" => { "from" => { "aws_secret" => Kong::Redactor::MARK }, "to" => { "aws_secret" => "sk_NEW" } } }
    result = split(after: after.merge("config" => { "aws_secret" => "sk_NEW" }), diff: diff)
    expect(result[:diff]["config"]["to"]["aws_secret"]).to eq(Kong::Redactor::MARK)
    expect(result[:sealed]["diff"]["config"]["to"]["aws_secret"]).to eq("sk_NEW")
  end

  it "seals by secret-looking names when the plugin's schema could not be read" do
    result = split(secret_paths: nil, after: { "name" => "x", "config" => { "api_token" => "t0k", "timeout" => 5 } })
    expect(result[:after]["config"]).to eq("api_token" => Kong::Redactor::MARK, "timeout" => 5)
    expect(result[:sealed]["after"]["config"]["api_token"]).to eq("t0k")
  end
end
