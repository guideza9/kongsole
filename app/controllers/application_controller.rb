class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :current_connection, :current_operator, :signed_in?

  private

  # The connection the current browser session is logged into, if any.
  #
  # There is no user database of this tool's own -- the Kong Admin API
  # credential *is* the login (docs/DESIGN.md section 3) -- so "session" here
  # means "which connection, and which secret, this browser is currently
  # authenticated against", not a user account.
  def current_connection
    return @current_connection if defined?(@current_connection)

    @current_connection = session[:connection_id] && KongConnection.find_by(id: session[:connection_id])
  end

  def current_operator
    session[:operator]
  end

  def signed_in?
    current_connection.present?
  end

  # A working Kong::Client for the current session's connection: the secret
  # comes back out of the encrypted session cookie for `session`-mode
  # credentials, or out of the encrypted DB column for `stored`-mode ones. It
  # is held only for the duration of the request and never assigned to an
  # instance variable a view could accidentally render.
  def current_client
    return nil unless current_connection

    Kong::Client.new(connection: current_connection, secret: current_secret)
  end

  # The raw credential behind current_client -- only handed to something
  # that needs to shell out with it directly (Kong::DeckCli, for a PR-mode
  # apply's `deck gateway diff`), never assigned to an instance variable a
  # view could render, never logged.
  def current_secret
    return nil unless current_connection

    current_connection.credential_mode == "stored" ? current_connection.auth_secret : session[:kong_secret]
  end

  def require_session!
    return if signed_in?

    redirect_to root_path, alert: "Log into a connection first."
  end
end
