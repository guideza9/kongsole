require "rails_helper"

RSpec.describe "Project envs", type: :request do
  let(:project) { create(:project, key: "project-x", source: "local") }

  it "creates a local direct env with a chosen rank for an 'other' name" do
    post project_envs_path, params: { project_env: { project_id: project.id, name: "nonprod", position: 1, rank: 1, apply_mode: "direct" } }
    expect(response).to redirect_to(project_path(project))
    expect(ProjectEnv.find_by!(name: "nonprod")).to have_attributes(rank: 1, apply_mode: "direct", source: "local")
  end

  it "leaves apply_mode unset when none is chosen" do
    post project_envs_path, params: { project_env: { project_id: project.id, name: "pt", position: 1, rank: 1, apply_mode: "" } }
    expect(ProjectEnv.find_by!(name: "pt").apply_mode).to be_nil
  end

  it "puts a new env after the project's others when no position is given" do
    create(:project_env, project: project, position: 4)
    post project_envs_path, params: { project_env: { project_id: project.id, name: "sit", apply_mode: "direct" } }
    expect(ProjectEnv.find_by!(name: "sit").position).to eq(5)
  end

  it "refuses pr from the UI" do
    post project_envs_path, params: { project_env: { project_id: project.id, name: "uat", position: 1, apply_mode: "pr" } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("PR mode is set in config/connections.yml")
    expect(ProjectEnv.count).to eq(0)
  end

  it "refuses to add an env to a project that came from connections.yml" do
    registry = create(:project, source: "registry")
    post project_envs_path, params: { project_env: { project_id: registry.id, name: "dev", apply_mode: "direct" } }
    expect(response).to have_http_status(:forbidden)
    expect(ProjectEnv.count).to eq(0)
  end

  it "refuses to edit an env that came from connections.yml" do
    env = create(:project_env, project: project, source: "registry", apply_mode: "pr")
    patch project_env_path(env), params: { project_env: { apply_mode: "direct" } }
    expect(response).to have_http_status(:forbidden)
    expect(env.reload.apply_mode).to eq("pr")
  end

  it "edits a local env, and can set its apply_mode back to not set" do
    env = create(:project_env, project: project, name: "pt", rank: 1, apply_mode: "direct")
    patch project_env_path(env), params: { project_env: { apply_mode: "" } }
    expect(response).to redirect_to(project_path(project))
    expect(env.reload.apply_mode).to be_nil
  end

  it "refuses to delete an env that still has a connection" do
    env = create(:project_env, project: project)
    create(:kong_connection, project_env: env)
    delete project_env_path(env)
    expect(response).to redirect_to(project_path(project))
    expect(ProjectEnv.exists?(env.id)).to be(true)
  end

  it "deletes a local env with no connection" do
    env = create(:project_env, project: project)
    delete project_env_path(env)
    expect(response).to redirect_to(project_path(project))
    expect(ProjectEnv.exists?(env.id)).to be(false)
  end
end
