# One env of a project -- the single place its policy lives: rank (how loud
# the UI is and which guardrails apply) and apply_mode (how, or whether, a
# change is written). A connection copies both from here (R1.2).
class ProjectEnv < ApplicationRecord
  KNOWN_RANKS = { "dev" => 0, "sit" => 1, "uat" => 2, "prod" => 3 }.freeze
  NAME_FORMAT = Project::KEY_FORMAT
  APPLY_MODES = %w[direct pr].freeze

  belongs_to :project, inverse_of: :project_envs
  has_one :kong_connection, dependent: :restrict_with_error

  validates :name, presence: true, format: { with: NAME_FORMAT, message: "must be lower-case letters, digits and dashes" },
    uniqueness: { scope: :project_id }
  validates :position, presence: true, numericality: { only_integer: true }, uniqueness: { scope: :project_id }
  validates :rank, presence: true, inclusion: { in: 0..3 }
  validates :apply_mode, inclusion: { in: APPLY_MODES }, allow_nil: true
  validates :source, inclusion: { in: Project::SOURCES }
  validate :pr_only_from_registry

  before_validation :normalize_name
  before_validation :force_known_rank
  before_validation :default_color_tag_from_rank

  # "known" when the name fixes the rank (dev/sit/uat/prod), "other" when
  # someone had to choose it.
  def rank_kind
    KNOWN_RANKS.key?(name) ? "known" : "other"
  end

  # :pr / :direct / :unset -- :unset means nothing can be written (R1.3).
  def write_policy
    apply_mode.present? ? apply_mode.to_sym : :unset
  end

  def qualified_name
    "#{project&.key}/#{name}"
  end

  private

  def normalize_name
    self.name = name.to_s.strip.downcase if name
  end

  # A dev/sit/uat/prod env always has that name's rank, whatever was
  # assigned: guardrails key off rank and must never disagree with the name.
  def force_known_rank
    self.rank = KNOWN_RANKS.fetch(name) if KNOWN_RANKS.key?(name)
  end

  def default_color_tag_from_rank
    return if color_tag.present? || rank.nil?

    self.color_tag = %w[green yellow orange red].fetch(rank, "green")
  end

  # PR mode is what makes a change reviewable by the CAB (CLAUDE.md rule 1);
  # it can only come from the registry file, never be set or dropped in the UI.
  def pr_only_from_registry
    return unless apply_mode == "pr" && source != "registry"

    errors.add(:apply_mode, "pr can only be set in config/connections.yml")
  end
end
