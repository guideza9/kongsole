# rank >= 2 (uat/prod): the credential is re-entered immediately before a
# write leaves Kongsole -- a direct apply or a changeset submit (docs/DESIGN.md
# section 10 step 5). The password is checked against Kong itself and never
# kept.
module Reauthentication
  extend ActiveSupport::Concern

  REAUTH_RANK_THRESHOLD = 2

  private

  def requires_reauth?(connection = current_connection)
    connection.rank >= REAUTH_RANK_THRESHOLD
  end

  def reauthenticated?
    return false if params[:password].blank?

    Kong::Client.new(connection: current_connection, secret: params[:password]).get("/")
    true
  rescue Kong::Client::Error
    false
  end

  # uat/prod: the connection's name retyped, so the env is said, not assumed.
  def env_name_confirmed?(connection = current_connection)
    !connection.protected_env? || params[:confirm_env_name].to_s.strip.casecmp?(connection.name)
  end
end
