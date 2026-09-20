# The audit log -- docs/DESIGN.md section 14. Scoped to the session's
# current connection, newest first; audit_events themselves are append-only
# (AuditEvent#readonly?), so this is a pure read.
class AuditEventsController < ApplicationController
  before_action :require_session!

  def index
    @audit_events = AuditEvent.where(kong_connection: current_connection).order(created_at: :desc).limit(200)
  end
end
