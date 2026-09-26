require "rails_helper"

RSpec.describe "Project overview", type: :request do
  include ActiveSupport::Testing::TimeHelpers

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

    # The count is its own element (a number that lines up across envs), so read the text, not the markup.
    expect(Nokogiri::HTML(response.body).text.squish).to include("3 routes", "Never synced on this machine")
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

  it "puts each env's counts in its own row, and a Trace link only on synced envs" do
    create(:kong_entity, kong_connection: dev_conn, entity_type: "service")
    create(:kong_connection, project_env: uat)

    get project_path(project.key)
    page = Nokogiri::HTML(response.body)

    dev_row = page.at_css('[data-env-name="dev"]')
    uat_row = page.at_css('[data-env-name="uat"]')
    expect(dev_row.at_css(".env-row__counts").text.squish).to include("1 service")
    expect(dev_row.at_css(%(a[href="#{project_trace_path(project.key, env: 'dev')}"]))).to be_present
    expect(uat_row.text).to include("Never synced on this machine")
    expect(uat_row.at_css(%(a[href*="/trace"]))).to be_nil
  end

  it "keeps the connections page without counts" do
    create(:kong_entity, kong_connection: dev_conn, entity_type: "service")
    get connections_path
    expect(response.body).not_to include("env-row__counts")
  end

  it "says how old a sync is once it is more than a day old" do
    travel_to Time.utc(2026, 9, 26, 12) do
      create(:kong_entity, kong_connection: dev_conn, synced_at: Time.utc(2026, 9, 20, 11, 5))
      get project_path(project.key)
      counts = Nokogiri::HTML(response.body).at_css('[data-env-name="dev"] .env-row__counts').text.squish
      expect(counts).to include("6 days old")
    end
  end

  it "points an unreachable env at the project's network note" do
    project.update!(network_note: "VPN corp-dc2")
    dev_conn.update!(last_status: "unreachable", last_connected_at: Time.utc(2026, 9, 24, 16, 2))

    get project_path(project.key)

    expect(Nokogiri::HTML(response.body).at_css('[data-env-name="dev"]').text.squish).to include("see Network above")
  end
end
