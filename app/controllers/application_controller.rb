class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :current_connection, :current_operator, :signed_in?, :detailed_hints?, :current_project_envs,
    :write_block_reason, :current_open_changeset, :can_propose_writes?

  private

  # R3: compact hints unless this browser chose detailed (HintPreferencesController).
  # Anything but "detailed" -- a missing or tampered cookie -- reads as compact
  # (owner decision 2026-09-26: the detailed default was too much text).
  def detailed_hints?
    cookies[:kongsole_hints] == "detailed"
  end

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

  # R1.7: the envs of the logged-in connection's project, in the project's
  # order, for the header switcher -- each with its connection (nil when the
  # env has none yet, so it shows but cannot be picked) and whether it is the
  # one this session is in. [] when nobody is logged in.
  def current_project_envs
    return @current_project_envs if defined?(@current_project_envs)

    project = current_connection&.project
    @current_project_envs =
      if project
        project.project_envs.includes(:kong_connection).map do |env|
          { env: env, connection: env.kong_connection, current: env.id == current_connection.project_env_id }
        end
      else
        []
      end
  end

  # R1.11: every Kong/network error explained with the project's network note
  # on a network problem -- "join the NONPROD VPN", not "Kong is down".
  def explain_error(error, connection: current_connection)
    Kong::ErrorExplanation.for(error, network_note: connection&.network_note)
  end

  def current_operator
    session[:operator]
  end

  # R8: the open changeset of the logged-in connection, or nil (direct mode,
  # or nothing collected yet) -- for the nav's item count.
  def current_open_changeset
    return @current_open_changeset if defined?(@current_open_changeset)

    @current_open_changeset = current_connection && Changeset.find_by(kong_connection: current_connection, status: "open")
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

  # R1.13: why this session cannot write (KongConnection#write_block_reason),
  # or nil -- nil too when nobody is logged in. Views hide write controls on it.
  def write_block_reason
    current_connection&.write_block_reason
  end

  # R2: the one answer to "show a write button?" -- a PR env (it writes to
  # git), or a direct env whose credential can write; never an env whose
  # apply mode is unset.
  def can_propose_writes?
    signed_in? && write_block_reason.nil?
  end

  # R1.13: a write form never opens where the write would be refused; the
  # reason is the guardrail's own message. `back_to` is where the list is.
  def require_writable!(back_to:)
    message = current_connection && Kong::ChangeGuardrails.write_block_message(current_connection)
    redirect_to back_to, alert: message if message
  end
end
