require "rails_helper"

RSpec.describe "Projects", type: :request do
  it "creates a local project" do
    post projects_path, params: { project: { key: "project-x", name: "Project X" } }
    expect(response).to redirect_to(connections_path)
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
end
