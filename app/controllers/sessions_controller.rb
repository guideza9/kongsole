# The "login of a connection" flow from docs/DESIGN.md section 3: pick a
# connection, supply its Kong Admin API basic-auth credential (and an
# operator name if it's shared), and run the full login pipeline
# (Kong::ConnectionLogin) -- auth, access-level probe, credential
# classification, admin-path discovery -- before the session is trusted.
class SessionsController < ApplicationController
  def new
    @connection = KongConnection.find(params[:id])
  end

  def create
    @connection = KongConnection.find(params[:id])

    result = Kong::ConnectionLogin.new(
      connection: @connection,
      username: params[:username],
      secret: params[:password],
      operator: params[:operator].presence
    ).call

    if result.success?
      session[:connection_id] = @connection.id
      session[:operator] = params[:operator].presence
      # Only a `session`-mode credential lives in the (encrypted, signed)
      # session cookie; a `stored`-mode one is already persisted, encrypted,
      # on the connection record by Kong::ConnectionLogin, so nothing
      # secret-bearing needs to ride in the cookie for that mode.
      session[:kong_secret] = params[:password] if @connection.credential_mode == "session"

      redirect_to health_path, notice: "Connected to \"#{@connection.name}\" (#{@connection.access_level}, #{@connection.credential_kind} credential)."
    else
      flash.now[:alert] = login_error_message(result)
      flash.now[:error_explanation] = explain_error(result.exception, connection: @connection).to_flash if result.exception
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    reset_session
    redirect_to root_path, notice: "Signed out."
  end

  private

  # R3: a Kong or network failure is named by its hints.errors title; the
  # layout prints the cause and next step under it (flash[:error_explanation]).
  # A login-pipeline refusal with no exception (operator name missing) keeps
  # its own message.
  def login_error_message(result)
    return result.error unless result.exception

    explain_error(result.exception, connection: @connection).title
  end
end
