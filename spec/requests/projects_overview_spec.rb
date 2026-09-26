require "rails_helper"

RSpec.describe "Project overview", type: :request do
  let(:project) { create(:project, key: "project-a") }
  let!(:dev) { create(:project_env, project: project, name: "dev", position: 1) }
  let!(:uat) { create(:project_env, project: project, name: "uat", position: 2) }
  let!(:dev_conn) { create(:kong_connection, project_env: dev) }
  let(:notes_dir) { Pathname(Dir.mktmpdir) }

  before { stub_const("ProjectNotes::DIR", notes_dir) }

  it "shows counts and sync per env, without logging in and without calling Kong" do
    create_list(:kong_entity, 3, kong_connection: dev_conn, entity_type: "route", synced_at: Time.utc(2026, 9, 26, 9, 14))
    create(:kong_connection, project_env: uat)

    get project_path(project.key)

    expect(response.body).to include("3 routes", "Never synced on this machine")
    expect(response.body).to include(project_trace_path(project.key))
    expect(a_request(:any, //)).not_to have_been_made
  end

  it "renders the team notes" do
    notes_dir.join("project-a.md").write("## Owners\n\n- Payments Core squad")
    get project_path(project.key)
    expect(response.body).to include("<h2>Owners</h2>", "Payments Core squad")
  end

  it "says how to add notes when there are none" do
    get project_path(project.key)
    expect(response.body).to include("kong:project_notes[project-a]", "config/projects/project-a.md")
  end
end
