# R8: the PR-mode plans of one connection, collected until a person submits
# them as one branch and one PR (docs/requirements/R8-pr-mode-changeset.md).
# One open changeset per connection; direct mode has none -- its plans apply
# one at a time. A changeset never expires: its items wait for the submit.
class Changeset < ApplicationRecord
  STATUSES = %w[open submitted abandoned].freeze

  belongs_to :kong_connection
  has_many :change_plans, dependent: :nullify

  validates :status, inclusion: { in: STATUSES }
  validates :actor_username, presence: true

  # The connection's open changeset, or a new one. Only PR mode collects:
  # a direct-mode write applies on its own.
  def self.open_for!(connection:, actor_username:, actor_operator:)
    unless connection.apply_mode == "pr"
      raise Kong::ChangeGuardrails::Violation, "#{connection.name} is not in PR mode -- only PR-mode changes collect in a changeset"
    end

    find_by(kong_connection: connection, status: "open") ||
      create!(kong_connection: connection, status: "open", actor_username: actor_username, actor_operator: actor_operator)
  rescue ActiveRecord::RecordNotUnique
    find_by!(kong_connection: connection, status: "open")
  end

  # What will go into the branch, in the order it will be rendered.
  def items
    change_plans.pending.order(:position, :id)
  end

  def open?
    status == "open"
  end

  def connection
    kong_connection
  end

  def branch_url
    branch.present? ? kong_connection.branch_url(branch) : nil
  end
end
