require "rails_helper"

RSpec.describe ProjectEnv do
  let(:project) { create(:project, key: "project-a") }

  it "forces the rank of a known env name, whatever case it is typed in" do
    env = described_class.create!(project: project, name: "Prod", position: 1, rank: 0, apply_mode: nil)
    expect(env).to have_attributes(name: "prod", rank: 3) # name is down-cased before validation
  end

  it "rejects a name that cannot be part of project/env" do
    expect(described_class.new(project: project, name: "pre prod", position: 1, rank: 3)).not_to be_valid
  end

  it "requires an explicit rank for an env name it does not know, with no default" do
    env = described_class.new(project: project, name: "pt", position: 1)
    expect(env).not_to be_valid
    expect(env.errors[:rank]).to be_present
    env.rank = 1
    expect(env).to be_valid
    expect(env.rank_kind).to eq("other")
  end

  it "keeps rank within 0..3" do
    expect(described_class.new(project: project, name: "ps", position: 1, rank: 4)).not_to be_valid
  end

  it "allows apply_mode to be unset and says nothing can be written" do
    env = described_class.create!(project: project, name: "dev", position: 1, apply_mode: nil)
    expect(env.write_policy).to eq(:unset)
  end

  it "never lets a local env be PR mode -- only connections.yml can" do
    env = described_class.new(project: project, name: "uat", position: 1, apply_mode: "pr", source: "local")
    expect(env).not_to be_valid
    expect(env.errors[:apply_mode].join).to match(/connections\.yml/)
  end

  it "orders envs by position and keeps positions unique per project" do
    described_class.create!(project: project, name: "dev", position: 1)
    expect(described_class.new(project: project, name: "sit", position: 1)).not_to be_valid
  end

  it "names itself project/env" do
    env = described_class.create!(project: project, name: "sit", position: 2)
    expect(env.qualified_name).to eq("project-a/sit")
  end
end
