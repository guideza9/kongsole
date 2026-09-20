# A bearer token for the MCP-facing REST API (docs/DESIGN.md section 12).
# Bound to an operator (the person it's attributed to in the audit trail --
# never blank, even when issued under a personal credential) and a set of
# connections, restricted to credential_mode: "stored" ones only: a
# session-mode connection's secret only ever lives in a browser cookie, so
# there is nothing server-held for a PAT-authenticated request to use.
#
# The raw token exists only for the instant .issue! returns it -- only
# token_digest (SHA256) is ever persisted. Revoking sets revoked_at rather
# than destroying the row, so it stays visible in the token list and in
# anything it's attributed to.
class PersonalAccessToken < ApplicationRecord
  TOKEN_PREFIX = "kctl_"

  class IneligibleConnection < StandardError; end

  has_many :personal_access_token_connections, dependent: :destroy
  has_many :kong_connections, through: :personal_access_token_connections

  validates :operator, presence: true
  validates :issued_by_username, presence: true
  validates :token_digest, presence: true, uniqueness: true
  validates :token_prefix, presence: true

  scope :active, -> { where(revoked_at: nil) }

  def self.issue!(operator:, issued_by_username:, connection_ids:, name: nil)
    connections = KongConnection.where(id: connection_ids)
    ineligible = connections.where.not(credential_mode: "stored")
    if ineligible.any?
      raise IneligibleConnection,
        "#{ineligible.pluck(:name).join(', ')} — a PAT can only reach credential_mode: stored connections " \
        "(a session-mode connection's secret only lives in a browser cookie, never on the server)"
    end

    raw_token = TOKEN_PREFIX + SecureRandom.hex(24)

    pat = transaction do
      record = create!(
        name: name.presence,
        operator: operator,
        issued_by_username: issued_by_username,
        token_digest: Digest::SHA256.hexdigest(raw_token),
        token_prefix: raw_token[0, 12]
      )
      connections.find_each { |connection| record.kong_connections << connection }
      record
    end

    [ pat, raw_token ]
  end

  def self.authenticate(raw_token)
    return nil if raw_token.blank?

    pat = active.find_by(token_digest: Digest::SHA256.hexdigest(raw_token))
    pat&.update_column(:last_used_at, Time.current) # rubocop:disable Rails/SkipsModelValidations -- a login timestamp touch, not a data change
    pat
  end

  def revoked?
    revoked_at.present?
  end

  def revoke!
    update!(revoked_at: Time.current)
  end
end
