# An append-only record of an applied change, per docs/DESIGN.md section 10
# (step 7: "Record") and section 13 ("audit_events ในเครื่อง"). Attribution
# is username + operator, never just username, so a shared credential's
# writes still trace to a person (docs/DESIGN.md section 2).
#
# Immutable once created -- `readonly?` makes any post-create save raise
# ActiveRecord::ReadOnlyRecord, enforcing "append-only" at the model layer
# rather than by convention alone.
class AuditEvent < ApplicationRecord
  belongs_to :kong_connection
  belongs_to :change_plan, optional: true

  validates :actor_username, presence: true
  validates :operation, presence: true
  validates :entity_type, presence: true

  def readonly?
    !new_record?
  end
end
