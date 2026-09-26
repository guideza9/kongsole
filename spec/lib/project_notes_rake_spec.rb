require "rails_helper"
require "rake"

RSpec.describe "kong:project_notes" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("kong:project_notes") }
  let(:dir) { Pathname(Dir.mktmpdir) }

  before { stub_const("ProjectNotes::DIR", dir) }
  after { Rake::Task["kong:project_notes"].reenable }

  it "writes the four-heading skeleton once and never overwrites it" do
    create(:project, key: "project-a")
    Rake::Task["kong:project_notes"].invoke("project-a")
    body = dir.join("project-a.md").read
    expect(body).to include("## Business flow", "## Owners", "## Who to contact", "## Before you change anything")

    dir.join("project-a.md").write("kept")
    Rake::Task["kong:project_notes"].reenable
    expect { Rake::Task["kong:project_notes"].invoke("project-a") }.to output(/already exists/).to_stdout
    expect(dir.join("project-a.md").read).to eq("kept")
  end

  it "refuses a key that is not a project" do
    expect { Rake::Task["kong:project_notes"].invoke("../etc") }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
