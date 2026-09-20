# The expiry dashboard (docs/DESIGN.md section 8: "ผลพลอยได้ — dashboard cert
# หมดอายุ"). Scoped to the session's *current connection* on purpose: a web
# session holds one connection's credential and the header shows that
# connection's colour badge, so a cross-connection table would blur the
# environment guardrail DESIGN section 14 calls the cheapest and most
# effective. The estate-wide view is the REST/MCP `kong_certs_expiring`.
#
# Reads the read-model only -- nothing here calls Kong.
class CertificatesController < ApplicationController
  before_action :require_session!

  DEFAULT_DAYS = 30
  MAX_DAYS = 3650
  WINDOWS = [ 7, 30, 90 ].freeze

  def expiring
    @days = normalized_days
    scope = KongEntity.active.where(kong_connection: current_connection, entity_type: %w[certificate ca_certificate])
    @entities = scope.expiring_within(@days).order(:not_after, :id)
    @last_synced_at = scope.maximum(:synced_at)
  end

  private

  def normalized_days
    raw = params[:days]
    days = raw.is_a?(String) ? raw.to_i : 0 # days[]=1 / days[a]=1 arrive as Array / Parameters
    days.between?(1, MAX_DAYS) ? days : DEFAULT_DAYS
  end
end
