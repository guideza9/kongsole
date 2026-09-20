# A registry entry for one Kong Gateway CE Admin API endpoint.
#
# There is no separate user database for this tool: the Kong Admin API
# credential *is* the login (see docs/DESIGN.md section 3). `auth_secret` is
# only ever populated for `credential_mode: stored` connections and is
# transparently encrypted at rest; it is never exposed through `to_json`,
# `inspect`, or any serializer.
class KongConnection < ApplicationRecord
  RANKS = { "dev" => 0, "sit" => 1, "uat" => 2, "prod" => 3 }.freeze
  ENVS = RANKS.keys.freeze
  CREDENTIAL_KINDS = %w[personal shared].freeze
  CREDENTIAL_MODES = %w[session stored].freeze
  ACCESS_LEVELS = %w[rw ro].freeze
  APPLY_MODES = %w[direct pr].freeze
  AUTH_TYPES = %w[basic none header].freeze
  STATUSES = %w[ok unauthorized forbidden route_not_matched not_found rate_limited unavailable error].freeze

  encrypts :auth_secret

  validates :name, presence: true, uniqueness: true
  validates :env, inclusion: { in: ENVS }
  validates :rank, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :admin_url, presence: true
  validates :auth_type, inclusion: { in: AUTH_TYPES }
  validates :credential_kind, inclusion: { in: CREDENTIAL_KINDS }, allow_nil: true
  validates :credential_mode, inclusion: { in: CREDENTIAL_MODES }
  validates :access_level, inclusion: { in: ACCESS_LEVELS }, allow_nil: true
  validates :apply_mode, inclusion: { in: APPLY_MODES }
  validates :last_status, inclusion: { in: STATUSES }, allow_nil: true
  validate :admin_url_must_be_https_unless_localhost

  before_validation :default_color_tag_from_env, on: :create

  def prod?
    env == "prod"
  end

  def shared_credential?
    credential_kind == "shared"
  end

  def read_only?
    access_level == "ro"
  end

  def admin_path?(kong_id)
    Kong::AdminPathGuard.admin_path?(admin_path_fingerprint, kong_id)
  end

  # Lets the connection form submit `select_tags` as one comma-separated
  # field instead of a real array input.
  def select_tags_raw
    Array(select_tags).join(",")
  end

  def select_tags_raw=(value)
    self.select_tags = value.to_s.split(",").map(&:strip).reject(&:blank?)
  end

  # `auth_secret` is never included in inspect/to_s output, even though it's
  # a real attribute, to keep it out of logs, console history, and error
  # reports (see the log-safety spec in spec/services/kong/client_spec.rb).
  def inspect
    super.gsub(/auth_secret: "[^"]*"/, 'auth_secret: "[FILTERED]"')
  end

  private

  def default_color_tag_from_env
    return if color_tag.present?

    self.color_tag = case env
    when "prod" then "red"
    when "uat" then "orange"
    when "sit" then "yellow"
    else "green"
    end
  end

  def admin_url_must_be_https_unless_localhost
    return if admin_url.blank?

    uri = begin
      URI.parse(admin_url)
    rescue URI::InvalidURIError
      errors.add(:admin_url, "is not a valid URL")
      return
    end

    return if uri.scheme == "https"
    return if %w[localhost 127.0.0.1 ::1].include?(uri.host)
    return if allow_insecure_http?

    errors.add(:admin_url, "must use https:// unless it points at localhost, or allow_insecure_http is set in connections.yml (see docs/DESIGN.md section 3 -- this is a config-file-only escape hatch, never a UI checkbox)")
  end
end
