require "rails_helper"

RSpec.describe Project do
  it "requires a lower-case key usable in project/env names" do
    expect(build(:project, key: "Project A")).not_to be_valid
    expect(build(:project, key: "project-a")).to be_valid
  end

  it "keeps project keys unique regardless of case" do
    create(:project, key: "project-a")
    expect(build(:project, key: "project-a")).not_to be_valid
  end

  it "defaults the changeset delete threshold to 3" do
    expect(create(:project).delete_threshold).to eq(3)
  end

  it "keeps the network note short enough to sit under an error" do
    expect(build(:project, network_note: "x" * 201)).not_to be_valid
    expect(build(:project, network_note: "Reachable from the NONPROD VPN only")).to be_valid
  end
end
