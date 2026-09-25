require "rails_helper"

# R1.18: the connections page filter. Every term has to match the project
# (name or key) or one of its envs; the envs a term named are marked so the
# page can say which env the query found.
RSpec.describe ProjectFilter do
  let!(:pay)  { create(:project, key: "payments", name: "Payments") }
  let!(:card) { create(:project, key: "card-switch", name: "Card Switch") }

  before do
    %w[dev sit uat].each_with_index { |name, i| create(:project_env, project: pay, name: name, position: i + 1) }
    %w[nonprod pt].each_with_index { |name, i| create(:project_env, project: card, name: name, position: i + 1) }
  end

  def run(query)
    described_class.new(Project.includes(:project_envs).order(:name), query).call
  end

  it "keeps every project, in order, and marks no env when the query is blank" do
    result = run(" ")
    expect(result.map(&:project)).to eq([ card, pay ])
    expect(result.flat_map(&:matched_env_ids)).to be_empty
  end

  it "matches a project by its name or its key, whatever the case" do
    expect(run("PAY").map(&:project)).to eq([ pay ])
    expect(run("card-sw").map(&:project)).to eq([ card ])
  end

  it "needs every term to match, and marks the envs a term named" do
    result = run("pay uat")
    expect(result.map(&:project)).to eq([ pay ])
    expect(result.first.matched_env_ids).to eq([ pay.project_envs.find_by!(name: "uat").id ])
  end

  it "finds a project by an env name alone" do
    expect(run("nonprod").map(&:project)).to eq([ card ])
  end

  it "returns nothing when one term matches nowhere in the project" do
    expect(run("pay nonprod")).to be_empty
  end
end
