# Registry CRUD for KongConnection rows -- the connection list/add/edit/delete
# screen from docs/DESIGN.md section 14. This never touches credentials:
# adding or editing a connection here only records where a Kong Admin API
# lives and how apply/PR/color rules apply to it. Supplying a credential and
# actually authenticating happens in SessionsController.
class ConnectionsController < ApplicationController
  include RegistryGuard

  before_action :set_connection, only: %i[show edit update destroy]
  before_action :refuse_registry_connection, only: %i[edit update destroy]

  # R1: grouped by project, envs in each project's own order.
  def index
    @projects = Project.includes(project_envs: :kong_connection).order(:name)
  end

  def show
  end

  def new
    @connection = KongConnection.new(credential_mode: "session", auth_type: "basic", verify_ssl: true)
  end

  def create
    @connection = KongConnection.new(connection_params)
    env = @connection.project_env
    return refuse_registry("Environment #{env.qualified_name}") if env && env.source != "local"

    if @connection.save
      redirect_to connections_path, notice: "Connection \"#{@connection.name}\" added."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    @connection.assign_attributes(connection_params)
    env = @connection.project_env
    return refuse_registry("Environment #{env.qualified_name}") if env && env.source != "local"

    if @connection.save
      redirect_to connections_path, notice: "Connection \"#{@connection.name}\" updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    name = @connection.name
    @connection.destroy
    redirect_to connections_path, notice: "Connection \"#{name}\" removed from the registry."
  end

  private

  def set_connection
    @connection = KongConnection.find(params[:id])
  end

  def refuse_registry_connection
    refuse_registry("Connection #{@connection.name}") unless @connection.editable_in_ui?
  end

  # R1: name, env, rank, apply_mode and git settings come from the env
  # (KongConnection#copy_policy_from_env), never from this form.
  def connection_params
    params.require(:kong_connection).permit(
      :project_env_id, :admin_url, :auth_type, :credential_mode, :verify_ssl, :ca_bundle_path
    )
  end
end
