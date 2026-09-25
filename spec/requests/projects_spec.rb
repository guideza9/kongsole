require "rails_helper"

RSpec.describe "Projects", type: :request do
  it "creates a local project" do
    post projects_path, params: { project: { key: "project-x", name: "Project X" } }
    expect(response).to redirect_to(project_path(Project.find_by!(key: "project-x")))
    expect(Project.find_by!(key: "project-x")).to have_attributes(name: "Project X", source: "local")
  end

  it "shows what is wrong with a key that cannot name project/env" do
    post projects_path, params: { project: { key: "Project X", name: "Project X" } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(Project.count).to eq(0)
  end

  it "edits a local project but keeps its key" do
    project = create(:project, key: "project-x", source: "local")
    patch project_path(project), params: { project: { name: "Renamed", key: "other" } }
    expect(project.reload).to have_attributes(name: "Renamed", key: "project-x")
  end

  it "refuses to edit a project that came from connections.yml" do
    project = create(:project, key: "project-a", name: "Project A", source: "registry")
    patch project_path(project), params: { project: { name: "Renamed" } }
    expect(response).to have_http_status(:forbidden)
    expect(project.reload.name).to eq("Project A")
  end

  # R1.18: a project's page holds its envs and what edits them.
  it "shows a project from connections.yml, with its envs in their order" do
    project = create(:project, key: "pay", name: "Pay", source: "registry")
    create(:project_env, project: project, name: "uat", position: 2, source: "registry", apply_mode: "pr")
    create(:project_env, project: project, name: "dev", position: 1, source: "registry")
    get project_path(project)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Pay")
    expect(response.body.index(">dev<")).to be < response.body.index(">uat<")
  end

  it "shows a local project" do
    project = create(:project, key: "project-x", name: "Project X", source: "local")
    get project_path(project)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Project X")
  end

  it "goes back to the project's page after editing it" do
    project = create(:project, key: "project-x", source: "local")
    patch project_path(project), params: { project: { name: "Renamed" } }
    expect(response).to redirect_to(project_path(project))
  end

  it "sets a local project's network note (R1.11)" do
    project = create(:project, key: "project-x", source: "local")
    patch project_path(project), params: { project: { network_note: "Reachable from the NONPROD VPN only" } }
    expect(project.reload.network_note).to eq("Reachable from the NONPROD VPN only")
  end
end
