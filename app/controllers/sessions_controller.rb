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
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    reset_session
    redirect_to root_path, notice: "Signed out."
  end

  private

  def login_error_message(result)
    case result.error_class&.name
    when "Kong::Client::Unauthorized"
      "Credential rejected: wrong username or password."
    when "Kong::Client::Forbidden"
      "Credential rejected: this consumer is not in an allowed ACL group."
    when "Kong::Client::RouteNotMatched"
      "No route matched at this connection's admin_url -- check the host/path, or this credential can't reach this route."
    when "Kong::Client::RateLimited"
      "Kong Admin API rate limit exceeded -- try again shortly."
    when "Kong::Client::UpstreamUnavailable"
      "Kong Admin API is unreachable (the loopback service may be down)."
    else
      result.error
    end
  end
end
