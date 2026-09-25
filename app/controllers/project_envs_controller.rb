# R1.5: local envs of local projects. Their apply_mode is direct or not set;
# PR mode can only come from config/connections.yml (CLAUDE.md rule 1), so a
# submitted "pr" is refused with 422, and envs from that file are not
# editable here at all (RegistryGuard).
class ProjectEnvsController < ApplicationController
  include RegistryGuard

  UI_APPLY_MODES = [ "", "direct" ].freeze

  before_action :set_env, only: %i[edit update destroy]
  before_action :refuse_registry_env, only: %i[edit update destroy]

  def new
    project = Project.find(params[:project_id])
    return refuse_registry("Project #{project.key}") unless project.source == "local"

    @project_env = project.project_envs.build(position: next_position(project))
  end

  def create
    project = Project.find(params.dig(:project_env, :project_id))
    return refuse_registry("Project #{project.key}") unless project.source == "local"

    @project_env = project.project_envs.build(env_params.merge(source: "local"))
    @project_env.position = next_position(project) if @project_env.position.blank?
    return refuse_pr unless apply_mode_allowed?

    if @project_env.save
      redirect_to project_path(project), notice: "Environment #{@project_env.qualified_name} added."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    @project_env.assign_attributes(env_params)
    return refuse_pr unless apply_mode_allowed?

    if @project_env.save
      # The connection keeps a copy of rank and apply_mode (KongConnection#copy_policy_from_env).
      @project_env.kong_connection&.save!
      redirect_to project_path(@project_env.project), notice: "Environment #{@project_env.qualified_name} updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    name = @project_env.qualified_name
    if @project_env.destroy
      redirect_to project_path(@project_env.project), notice: "Environment #{name} removed."
    else
      redirect_to project_path(@project_env.project), alert: "#{name} still has a connection -- remove the connection first."
    end
  end

  private

  def set_env
    @project_env = ProjectEnv.find(params[:id])
  end

  def refuse_registry_env
    refuse_registry("Environment #{@project_env.qualified_name}") unless @project_env.source == "local"
  end

  def env_params
    permitted = params.require(:project_env).permit(:name, :position, :rank, :apply_mode, :color_tag)
    permitted[:apply_mode] = permitted[:apply_mode].presence if permitted.key?(:apply_mode)
    permitted
  end

  def apply_mode_allowed?
    UI_APPLY_MODES.include?(params.dig(:project_env, :apply_mode).to_s)
  end

  def refuse_pr
    @project_env.errors.add(:apply_mode, "PR mode is set in config/connections.yml, not here")
    render(@project_env.persisted? ? :edit : :new, status: :unprocessable_entity)
  end

  def next_position(project)
    project.project_envs.maximum(:position).to_i + 1
  end
end
