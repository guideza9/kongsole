# One synced Kong entity (any registered type, see Kong::EntityTypes and
# Kong::EntitySync) in the read-model, per docs/DESIGN.md section 7. `data`
# has already been through Kong::Redactor by the time it lands here --
# nothing downstream needs to redact again.
class KongEntity < ApplicationRecord
  belongs_to :kong_connection

  validates :entity_type, presence: true
  validates :kong_id, presence: true, uniqueness: { scope: [ :kong_connection_id, :entity_type ] }

  scope :active, -> { where(deleted_at: nil) }
  scope :of_type, ->(type) { where(entity_type: type) }

  # docs/DESIGN.md section 8 / M5b spec section 5. Kong::CertificateMetadata
  # fills `not_after` at sync time; nothing here reads a certificate.
  EXPIRY_CRITICAL = 7.days
  EXPIRY_WARNING = 30.days

  scope :expiring_within, ->(days) { where.not(not_after: nil).where(not_after: ..days.to_i.days.from_now) }

  def expiry_status(now = Time.current)
    return nil if not_after.nil?
    return "expired" if not_after <= now
    return "critical" if not_after <= now + EXPIRY_CRITICAL
    return "warning" if not_after <= now + EXPIRY_WARNING

    "ok"
  end

  def admin_path?
    is_admin_path
  end
end
