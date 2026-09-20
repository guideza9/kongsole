# Issue / view / revoke PATs (docs/DESIGN.md section 14). Not scoped to
# the session's current connection -- see docs/UI-DESIGN.md-equivalent
# scope note in the M1 slice 3a plan: a stored-mode connection's secret is
# already reachable by anyone signed into the app, so a PAT is a new
# access path to an existing shared trust boundary, not a new privilege
# gated behind whichever connection you happen to be logged into.
class PersonalAccessTokensController < ApplicationController
  before_action :require_session!

  def index
    @tokens = PersonalAccessToken.order(created_at: :desc).includes(:kong_connections)
  end

  def new
    @eligible_connections = KongConnection.where(credential_mode: "stored").order(:rank, :name)
  end

  def create
    pat, raw_token = PersonalAccessToken.issue!(
      operator: params[:operator], name: params[:name],
      issued_by_username: current_connection.auth_username,
      connection_ids: Array(params[:connection_ids]).reject(&:blank?)
    )
    flash[:new_token] = raw_token
    flash[:new_token_id] = pat.id
    redirect_to personal_access_tokens_path, notice: "Token issued."
  rescue PersonalAccessToken::IneligibleConnection => e
    @eligible_connections = KongConnection.where(credential_mode: "stored").order(:rank, :name)
    flash.now[:alert] = e.message
    render :new, status: :unprocessable_entity
  end

  def revoke
    token = PersonalAccessToken.find(params[:id])
    token.revoke!
    redirect_to personal_access_tokens_path, notice: "Revoked #{token.name.presence || token.token_prefix}."
  end
end
