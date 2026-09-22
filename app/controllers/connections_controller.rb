# Registry CRUD for KongConnection rows -- the connection list/add/edit/delete
# screen from docs/DESIGN.md section 14. This never touches credentials:
# adding or editing a connection here only records where a Kong Admin API
# lives and how apply/PR/color rules apply to it. Supplying a credential and
# actually authenticating happens in SessionsController.
class ConnectionsController < ApplicationController
  before_action :set_connection, only: %i[show edit update destroy]

  def index
    @connections = KongConnection.order(:rank, :name)
  end

  def show
  end

  def new
    @connection = KongConnection.new(credential_mode: "session", apply_mode: "direct", auth_type: "basic", verify_ssl: true)
  end

  def create
    @connection = KongConnection.new(connection_params)
    if @connection.save
      redirect_to connections_path, notice: "Connection \"#{@connection.name}\" added."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @connection.update(connection_params)
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

  def connection_params
    params.require(:kong_connection).permit(
      :name, :env, :color_tag, :admin_url, :auth_type,
      :credential_mode, :apply_mode, :verify_ssl, :ca_bundle_path,
      :git_repo, :git_branch, :git_path, :select_tags_raw
    )
  end
end
