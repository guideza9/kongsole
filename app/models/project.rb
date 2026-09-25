# A group of envs that share one Kong estate: one config repo, one network.
# Connections are named `<project.key>/<env.name>` (R1), so the key has the
# same shape as an env name.
class Project < ApplicationRecord
  SOURCES = %w[registry local].freeze
  KEY_FORMAT = /\A[a-z0-9][a-z0-9-]{0,39}\z/
  NETWORK_NOTE_MAX = 200

  has_many :project_envs, -> { order(:position) }, dependent: :restrict_with_error, inverse_of: :project

  validates :key, presence: true, format: { with: KEY_FORMAT, message: "must be lower-case letters, digits and dashes" },
    uniqueness: { case_sensitive: false }
  validates :name, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :delete_threshold, numericality: { only_integer: true, greater_than: 0 }
  validates :network_note, length: { maximum: NETWORK_NOTE_MAX }

  # Routes name a project by its key (resources :projects, param: :key).
  def to_param
    key_was.presence || key
  end
end
