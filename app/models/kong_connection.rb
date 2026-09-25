# A registry entry for one Kong Gateway CE Admin API endpoint.
#
# There is no separate user database for this tool: the Kong Admin API
# credential *is* the login (see docs/DESIGN.md section 3). `auth_secret` is
# only ever populated for `credential_mode: stored` connections and is
# transparently encrypted at rest; it is never exposed through `to_json`,
# `inspect`, or any serializer.
class KongConnection < ApplicationRecord
  # The env names the legacy connection form still offers (R1.5 replaces it
  # with a choice of project env). Rank is never derived from this list any
  # more: it is copied from the env (ProjectEnv::KNOWN_RANKS).
  ENVS = ProjectEnv::KNOWN_RANKS.keys.freeze
  CREDENTIAL_KINDS = %w[personal shared].freeze
  CREDENTIAL_MODES = %w[session stored].freeze
  ACCESS_LEVELS = %w[rw ro].freeze
  APPLY_MODES = %w[direct pr].freeze
  AUTH_TYPES = %w[basic none header].freeze
  STATUSES = %w[ok unauthorized forbidden route_not_matched not_found rate_limited unavailable error].freeze

  encrypts :auth_secret

  # R1: the env owns rank, apply_mode and git settings; the connection keeps a
  # copy (copy_policy_from_env) so every existing reader of `rank` and
  # `apply_mode` stays as it was.
  belongs_to :project_env, optional: true

  validates :project_env, presence: true
  validates :project_env_id, uniqueness: true, allow_nil: true
  validates :name, presence: true, uniqueness: true
  validates :rank, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :admin_url, presence: true
  validates :auth_type, inclusion: { in: AUTH_TYPES }
  validates :credential_kind, inclusion: { in: CREDENTIAL_KINDS }, allow_nil: true
  validates :credential_mode, inclusion: { in: CREDENTIAL_MODES }
  validates :access_level, inclusion: { in: ACCESS_LEVELS }, allow_nil: true
  validates :apply_mode, inclusion: { in: APPLY_MODES }
  validates :last_status, inclusion: { in: STATUSES }, allow_nil: true
  validate :admin_url_must_be_https_unless_localhost
  validate :git_web_url_must_be_a_web_url

  before_validation :adopt_legacy_env, if: -> { project_env.nil? }
  before_validation :copy_policy_from_env

  def prod?
    env == "prod"
  end

  # Through the env, never cached apart from it: git settings are copied
  # from this project on save.
  def project
    project_env&.project
  end

  # "project-a/uat" -- how the API, MCP and the UI name a connection.
  def qualified_name
    project_env&.qualified_name
  end

  # Registry rows come from config/connections.yml and are edited there.
  def editable_in_ui?
    project_env&.source == "local"
  end

  # uat and prod (rank >= 2): where the UI turns loud -- solid env chrome,
  # a retyped name before applying. Decided by rank, never by `color_tag`, so
  # a mis-tagged prod connection cannot quietly lose the guardrail. Rank is
  # not an input: it is copied from the env (see copy_policy_from_env), and
  # ProjectEnv forces the rank of a dev/sit/uat/prod name, so a prod row
  # cannot be saved with a quiet rank.
  PROTECTED_RANK = 2
  PROD_RANK = 3

  def protected_env?
    rank >= PROTECTED_RANK
  end

  # "env-prod" / "env-uat" -- the CSS class that sets the --env colour, or nil
  # below rank 2 where the chrome stays quiet.
  def env_tone
    return nil unless protected_env?

    rank >= PROD_RANK ? "env-prod" : "env-uat"
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

  # Where a pushed branch can be read in a browser, or nil when this
  # connection has no web-facing git host (the local bare repo dev/uat runs
  # against, for one). `git_web_url` is a template rather than a base URL
  # because the four candidate hosts in PRODUCT.md disagree about the shape
  # of a branch URL -- GitHub/GitLab want /tree/<branch>, Bitbucket Cloud
  # /branch/<branch>, Azure DevOps ?version=GB<branch> -- and the host is
  # still undecided, so the registry names the shape and the tool only
  # substitutes. A template missing the placeholder is treated as unset
  # rather than silently linking to the repo root.
  BRANCH_PLACEHOLDER = "{branch}"
  # The template is rendered straight into an href, so the scheme is checked
  # here as well as validated on save: a scheme-less template would resolve
  # relative to Kongsole and navigate the operator to its own 404, and
  # anything exotic has no business in a link this page draws. Matched rather
  # than URI.parse'd because `{branch}` is not a legal URI character.
  WEB_URL_SCHEME = %r{\Ahttps?://}i

  def branch_url(branch)
    return nil if git_web_url.blank? || branch.blank?
    return nil unless git_web_url.include?(BRANCH_PLACEHOLDER)
    return nil unless git_web_url.match?(WEB_URL_SCHEME)

    git_web_url.gsub(BRANCH_PLACEHOLDER, escape_branch(branch))
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

  # Branch names carry a slash (`kongctl/<uuid>`), which is a real path
  # separator in every host's branch URL -- escaping it to %2F would break
  # the link. Each segment is escaped on its own so the separator survives.
  def git_web_url_must_be_a_web_url
    return if git_web_url.blank?
    return if git_web_url.match?(WEB_URL_SCHEME) && git_web_url.include?(BRANCH_PLACEHOLDER)

    errors.add(:git_web_url, "must be an http(s) URL containing #{BRANCH_PLACEHOLDER}")
  end

  def escape_branch(branch)
    branch.to_s.split("/", -1).map { |segment| ERB::Util.url_encode(segment) }.join("/")
  end

  # Overwrites whatever was assigned, on create and on every update: the
  # guardrails key off rank and apply_mode, so the connection must never
  # disagree with its env.
  def copy_policy_from_env
    return if project_env.nil?

    self.env = project_env.name
    self.rank = project_env.rank
    self.apply_mode = project_env.apply_mode
    self.color_tag = project_env.color_tag.presence || ProjectEnv.color_tag_for(project_env.rank)
    self.git_path = project_env.git_path
    self.select_tags = project_env.select_tags
    project = project_env.project
    self.git_repo = project&.git_repo
    self.git_branch = project&.git_branch
    self.git_web_url = project&.git_web_url
    self.name = project_env.qualified_name
  end

  # A connection that arrives with no env (the flat connections.yml list and
  # the connection form, until R1.4 and R1.5) gets one in project `default`,
  # the same way the migration placed legacy rows.
  def adopt_legacy_env
    return if name.blank? && env.blank?

    self.project_env = Kong::LegacyProjectBackfill.build_env_for(self)
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
