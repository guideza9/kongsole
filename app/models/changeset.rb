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

    existing = find_by(kong_connection: connection, status: "open")
    return existing if existing

    # Read before any row is written: it is network I/O, and nothing may wait
    # on it inside a database transaction.
    base = remote_head_sha(connection)
    begin
      transaction(requires_new: true) do
        create!(kong_connection: connection, status: "open", actor_username: actor_username, actor_operator: actor_operator,
          base_git_sha: base)
      end
    rescue ActiveRecord::RecordNotUnique
      # Another proposal opened it first; the savepoint rolled back, so the
      # caller's transaction (if any) is still usable.
      find_by!(kong_connection: connection, status: "open")
    end
  end

  # R8.5: where the changeset began, so a submit can tell whether git moved
  # since. A repo that cannot be read now still lets the changeset open; the
  # base is then unknown, and the submit asks for a look.
  def self.remote_head_sha(connection)
    Kong::GitClient.new(connection: connection).remote_head_sha
  rescue Kong::GitClient::Error
    nil
  end
  private_class_method :remote_head_sha

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
