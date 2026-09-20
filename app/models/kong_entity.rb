# One synced Kong entity (currently: services only, see Kong::EntitySync) in
# the read-model, per docs/DESIGN.md section 7. `data` has already been
# through Kong::Redactor by the time it lands here -- nothing downstream
# needs to redact again.
class KongEntity < ApplicationRecord
  belongs_to :kong_connection

  validates :entity_type, presence: true
  validates :kong_id, presence: true, uniqueness: { scope: [ :kong_connection_id, :entity_type ] }

  scope :active, -> { where(deleted_at: nil) }
  scope :of_type, ->(type) { where(entity_type: type) }

  def admin_path?
    is_admin_path
  end
end
