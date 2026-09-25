# R1.5: local projects -- the ones Kongsole creates. Projects from
# config/connections.yml are edited there (RegistryGuard).
class ProjectsController < ApplicationController
  include RegistryGuard

  before_action :set_project, only: %i[edit update]
  before_action :refuse_registry_project, only: %i[edit update]

  def new
    @project = Project.new
  end

  def create
    @project = Project.new(project_params.merge(key: params.dig(:project, :key), source: "local"))
    if @project.save
      redirect_to connections_path, notice: "Project \"#{@project.name}\" added."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @project.update(project_params)
      redirect_to connections_path, notice: "Project \"#{@project.name}\" updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_project
    @project = Project.find_by!(key: params[:key])
  end

  def refuse_registry_project
    refuse_registry("Project #{@project.key}") unless @project.source == "local"
  end

  # The key names every connection in the project (project/env), so it is
  # set once, at create.
  def project_params
    params.require(:project).permit(:name, :git_repo, :git_branch, :git_web_url)
  end
end
