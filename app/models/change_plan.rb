# A proposed create/update/delete against a live Kong entity, per
# docs/DESIGN.md section 10 (step 4: "Plan"). Reviewed via
# ChangePlansController#show, then either applied (Kong::ChangeApplier) or
# left to expire 15 minutes after it was proposed. A PR-mode plan sits in its
# connection's changeset (R8) and waits there, unexpired, for the submit.
class ChangePlan < ApplicationRecord
  belongs_to :kong_connection
  belongs_to :changeset, optional: true
  belongs_to :replaces_plan, class_name: "ChangePlan", optional: true

  OPERATIONS = %w[create update delete].freeze
  STATUSES = %w[pending applied failed expired cancelled].freeze
  DEFAULT_TTL = 15.minutes

  validates :actor_username, presence: true
  validates :operation, inclusion: { in: OPERATIONS }
  validates :entity_type, presence: true
  validates :apply_mode, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: "pending") }

  # R4.10: the real values behind a direct-mode plugin plan's "[REDACTED]"
  # (Kong::PlanSecretSeal) -- JSON of {"after" => ..., "diff" => ...}, read
  # only by Kong::ChangeApplier and gone once the plan stops being pending.
  encrypts :sealed_secrets
  before_save { self.sealed_secrets = nil unless status == "pending" }

  def expired?
    return false if in_changeset?

    Time.current > expires_at
  end

  def in_changeset?
    changeset_id.present?
  end

  # What to call the entity this plan changes: before's name for an
  # update/delete, after's for a create; a target's host:port.
  def entity_label
    Kong::EntityTypes.label(before, after)
  end

  def delete?
    operation == "delete"
  end

  def sealed
    sealed_secrets.present? ? JSON.parse(sealed_secrets) : nil
  end

  # What the applier sends Kong: the sealed real values when there are any.
  def unsealed_after
    sealed ? sealed["after"] : after
  end

  def unsealed_diff
    sealed ? sealed["diff"] : diff
  end

  # Whether the body the applier would send still says "[REDACTED]" -- a
  # plan whose seal is gone (a rollback, a hand edit) must not write the
  # mark into Kong as the secret.
  def redacted_payload?
    body = operation == "update" ? unsealed_diff.to_h.values.filter_map { |change| change["to"] if change.is_a?(Hash) } : unsealed_after
    body.to_json.include?(Kong::Redactor::MARK)
  end
end
