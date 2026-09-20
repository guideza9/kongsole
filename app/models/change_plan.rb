# A proposed create/update/delete against a live Kong entity, per
# docs/DESIGN.md section 10 (step 4: "Plan"). Reviewed via
# ChangePlansController#show, then either applied (Kong::ChangeApplier) or
# left to expire 15 minutes after it was proposed.
class ChangePlan < ApplicationRecord
  belongs_to :kong_connection

  OPERATIONS = %w[create update delete].freeze
  STATUSES = %w[pending applied failed expired cancelled].freeze
  DEFAULT_TTL = 15.minutes

  validates :actor_username, presence: true
  validates :operation, inclusion: { in: OPERATIONS }
  validates :entity_type, presence: true
  validates :apply_mode, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: "pending") }

  def expired?
    Time.current > expires_at
  end

  def delete?
    operation == "delete"
  end
end
