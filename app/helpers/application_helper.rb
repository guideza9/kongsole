module ApplicationHelper
  # The env color tag is a functional guardrail, not decoration
  # (docs/DESIGN.md section 14: "the color tag is the cheapest, most
  # effective guardrail against touching the wrong environment") -- it must
  # render as a legible badge everywhere a connection's identity appears,
  # never as a small decorative dot easy to miss under pressure. Rendered as
  # a flat dot + label chip (docs/UI-DESIGN.md) rather than a lit lamp.
  #
  # The colours themselves are CSS (`.chip-<tone>` in application.css); Ruby
  # only decides which tone a tag or status gets.
  COLOR_TAG_TONES = {
    "red" => "danger",
    "orange" => "caution",
    "yellow" => "warning",
    "green" => "ok",
    "gray" => "neutral"
  }.freeze

  # `env` is stored as the short token the config file and decK use. In a
  # sentence an operator reads under pressure -- "this writes to prod now" --
  # the token is the tool's shorthand, not the environment's name, so the
  # consequence copy on the review page spells it out. The tokens stay
  # verbatim wherever they are the identifier being configured (the
  # connections form, the registry), so only the prose is translated.
  ENV_DISPLAY_NAMES = {
    "dev" => "Development",
    "sit" => "SIT",
    "uat" => "UAT",
    "prod" => "Production"
  }.freeze

  # The registry stores policy as config tokens (`apply_mode: pr`,
  # `access_level: rw`). On a card an operator scans, the tokens read as
  # settings to decode; these are the words the review page already uses.
  APPLY_MODE_LABELS = { "direct" => "Direct apply", "pr" => "PR mode" }.freeze
  ACCESS_LEVEL_LABELS = { "rw" => "Read-write", "ro" => "Read-only" }.freeze
  CREDENTIAL_KIND_LABELS = { "personal" => "Personal credential", "shared" => "Shared credential" }.freeze

  def apply_mode_label(apply_mode)
    APPLY_MODE_LABELS.fetch(apply_mode.to_s) { apply_mode.to_s }
  end

  def access_level_label(access_level)
    ACCESS_LEVEL_LABELS[access_level.to_s]
  end

  def credential_kind_label(credential_kind)
    CREDENTIAL_KIND_LABELS[credential_kind.to_s]
  end

  # One tag per policy the connection has settled. Access level and
  # credential kind are only known after a login probe, so an unprobed
  # connection shows fewer tags rather than "unknown" ones.
  def connection_policy_labels(connection)
    [
      connection.apply_mode && apply_mode_label(connection.apply_mode),
      access_level_label(connection.access_level),
      credential_kind_label(connection.credential_kind)
    ].compact
  end

  # R1.8: how careful an env is, in words. A dev/sit/uat/prod name fixes its
  # rank, so the name says it; any other name had its rank chosen, so the
  # label shows both ("Other · rank 1").
  KNOWN_ENV_LABELS = { "dev" => "Dev", "sit" => "SIT", "uat" => "UAT", "prod" => "Prod" }.freeze

  def rank_label(env)
    KNOWN_ENV_LABELS.fetch(env.name) { "Other \u00b7 rank #{env.rank}" }
  end

  # ProjectEnv#write_policy in words. :unset is the one that stops work, so it
  # says what it means rather than naming a missing setting.
  WRITE_POLICY_LABELS = {
    pr: "PR mode",
    direct: "Direct apply",
    unset: "Apply mode not set \u2014 nothing can be written"
  }.freeze

  def write_policy_label(policy)
    WRITE_POLICY_LABELS.fetch(policy.to_sym)
  end

  def write_policy_tag(env)
    policy = env.write_policy
    content_tag :span, write_policy_label(policy), class: policy == :unset ? "tag tag-caution" : "tag"
  end

  # Where a project or env is changed: the team registry file, or this
  # machine's Kongsole.
  def source_badge(source)
    content_tag :span, source.to_s == "local" ? "Local only" : "From connections.yml", class: "tag"
  end

  # The env's own name as a chip, for a list already headed by its project.
  # Loud (solid --env) at rank >= 2 exactly like env_badge, by rank alone.
  def env_name_chip(env)
    if env.rank.to_i >= KongConnection::PROTECTED_RANK
      tone = env.rank.to_i >= KongConnection::PROD_RANK ? "env-prod" : "env-uat"
      label = content_tag(:span, env.name, class: "chip-env__label")
      return content_tag(:span, safe_join([ content_tag(:span, "", class: "chip-dot"), label ]), class: "chip chip-lg chip-env #{tone}", title: env.name)
    end

    tone = COLOR_TAG_TONES.fetch(env.color_tag.to_s, "neutral")
    # The name in its own span so a long one can end in an ellipsis where the
    # chip runs out of room (R1.19), as the uat/prod label does.
    content_tag :span, safe_join([ content_tag(:span, "", class: "chip-dot"), content_tag(:span, env.name, class: "chip__name") ]),
      class: "chip chip-lg chip-#{tone}", title: env.name
  end

  def env_display_name(connection)
    env = connection.env.to_s
    ENV_DISPLAY_NAMES.fetch(env) { env.presence || "this environment" }
  end

  # A solid, bordered env badge -- the primary "which environment am I
  # looking at" signal, sized to be read at a glance, not squinted at.
  #
  # R1.10: it names the project and the env. At uat/prod the env is spelled
  # out first ("PROD · Payments"), so the word is on every page and not only on
  # the review strip; below rank 2 the chip stays the quiet dot + "Payments ·
  # dev": dev and sit are not where a wrong click is costly. The connection's
  # own project/env name is the title.
  def env_badge(connection, size: :md)
    classes = size == :lg ? "chip chip-lg" : "chip"
    project_name = connection.project&.name

    # uat/prod: a solid chip chosen by rank, never by color_tag (and never
    # red -- red is reserved for errors). See KongConnection#env_tone.
    if connection.protected_env?
      parts = [ content_tag(:span, "", class: "chip-dot"), content_tag(:span, connection.env.upcase, class: "chip-env__label") ]
      if project_name.present?
        parts << content_tag(:span, "\u00b7", "aria-hidden": "true")
        parts << content_tag(:span, project_name, class: "chip-env__name")
      end
      return content_tag :span, safe_join(parts), class: "#{classes} chip-env #{connection.env_tone}", title: connection.name
    end

    tone = COLOR_TAG_TONES.fetch(connection.color_tag.to_s, "neutral")
    # Where the chip runs out of room, the project name gives way (ellipsis;
    # the full name is the title) and the env stays whole: the env is the
    # part that must never be misread.
    parts = [ content_tag(:span, "", class: "chip-dot") ]
    parts += [ content_tag(:span, project_name, class: "chip__project"), " \u00b7 " ] if project_name.present?
    parts << content_tag(:span, connection.env, class: "chip__env")
    content_tag :span, safe_join(parts), class: "#{classes} chip-#{tone}", title: connection.name
  end

  STATUS_TONES = {
    "ok" => "ok",
    "unauthorized" => "danger",
    "forbidden" => "danger",
    "route_not_matched" => "warning",
    "not_found" => "danger",
    "rate_limited" => "warning",
    "unavailable" => "danger",
    "error" => "danger",
    "expired" => "danger",
    "critical" => "danger",
    "warning" => "warning",
    # A change plan's own life, and a token's, read through the same badge.
    "applied" => "ok",
    "failed" => "danger",
    "pending" => "neutral",
    "revoked" => "danger",
    # R1.11: this machine cannot reach the node (VPN, DNS) -- not Kong's fault.
    "unreachable" => "warning",
    # Whether the admin path has been found on a connection.
    "guarded" => "ok",
    "unknown" => "neutral"
  }.freeze

  STATUS_LABELS = { "unreachable" => "Unreachable from this machine" }.freeze

  def status_label(status)
    STATUS_LABELS.fetch(status.to_s) { (status || "never connected").to_s.humanize }
  end

  ENTITY_TYPE_LABELS = {
    "service" => %w[Service Services],
    "route" => %w[Route Routes],
    "consumer" => %w[Consumer Consumers],
    "keyauth_credential" => %w[Key-auth\ credential Key-auth\ credentials],
    "basicauth_credential" => %w[Basic-auth\ credential Basic-auth\ credentials],
    "plugin" => %w[Plugin Plugins],
    "upstream" => %w[Upstream Upstreams],
    "target" => %w[Target Targets],
    "certificate" => %w[Certificate Certificates],
    "ca_certificate" => [ "CA certificate", "CA certificates" ],
    "sni" => %w[SNI SNIs]
  }.freeze

  def entity_type_label(entity_type, count: nil)
    singular, plural = ENTITY_TYPE_LABELS.fetch(entity_type.to_s, [ entity_type.to_s.humanize, entity_type.to_s.humanize.pluralize ])
    count.nil? ? plural : (count == 1 ? singular : plural)
  end

  def status_badge(status)
    tone = STATUS_TONES.fetch(status.to_s, "neutral")
    content_tag :span, safe_join([ content_tag(:span, "", class: "chip-dot"), status_label(status) ]), class: "chip chip-#{tone}"
  end

  # Syntax-highlights a Ruby value as pretty-printed JSON for the Raw JSON
  # panels on entities#show and change_plans#show -- plain black-on-gray
  # JSON is legible but slow to scan; color turns "find the tag that
  # changed" back into a glance instead of a read. Colors are defined in
  # .json-key/-string/-number/-bool/-null (app/assets/tailwind/application.css).
  #
  # This regex is the standard technique for highlighting JSON.pretty_generate
  # output: it walks the raw (unescaped) string once, and everything it does
  # NOT match -- braces, brackets, commas, the colon after a non-key match,
  # indentation -- passes through untouched, which is safe here specifically
  # because none of those structural characters need HTML escaping. Only
  # matched tokens (string/number/bool literals) are escaped before they're
  # wrapped, since a string value's content is the one place `<`, `&`, or
  # `"` could legitimately appear (e.g. a URL in a redacted field).
  JSON_TOKEN = /
    ("(?:\\u[a-fA-F0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?)  # string, optionally a key (captures trailing colon)
    |\b(?:true|false)\b
    |\bnull\b
    |-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?
  /x

  # A single before/after value in the change-plan diff table. Rendered as
  # JSON rather than Ruby's `inspect` -- entities are edited as JSON
  # documents, so `{"id"=>"abc"}` would be reviewing the change in the wrong
  # dialect from the one it was written in.
  def diff_value(value)
    value.to_json
  end

  # A single diff-table cell: the value plus which side of the change it's
  # on, so "what changed" reads from color before the field name is even
  # parsed. `tone` reuses the app's existing danger/success semantics
  # (removed = danger, added = success) rather than inventing a diff-
  # specific palette.
  def diff_chip(value, tone:)
    bg, fg = tone == :removed ? %w[--color-danger-tint --color-danger] : %w[--color-success-tint --color-success]
    content_tag :span, diff_value(value),
      class: "diff-chip font-mono text-xs",
      style: "background: var(#{bg}); color: var(#{fg})"
  end

  # Syntax-highlights a Ruby value as pretty-printed JSON for the Raw JSON
  # panels on entities#show and change_plans#show -- plain black-on-gray
  # JSON is legible but slow to scan; color turns "find the tag that
  # changed" back into a glance instead of a read. Colors are defined in
  # .json-key/-string/-number/-bool/-null (app/assets/tailwind/application.css).
  #
  # `changed_keys` + `tone` additionally tint the *line* for any top-level
  # field named in `changed_keys` (danger for the before panel's removed/old
  # values, success for the after panel's added/new ones) -- change_plans#show
  # passes the diff's own field names, so the two Raw JSON panels show
  # exactly what the Changes table already says, in place, rather than
  # requiring a mental merge between the two sections.
  #
  # This regex is the standard technique for highlighting JSON.pretty_generate
  # output: it walks the raw (unescaped) string once, and everything it does
  # NOT match -- braces, brackets, commas, the colon after a non-key match,
  # indentation -- passes through untouched, which is safe here specifically
  # because none of those structural characters need HTML escaping. Only
  # matched tokens (string/number/bool literals) are escaped before they're
  # wrapped, since a string value's content is the one place `<`, `&`, or
  # `"` could legitimately appear (e.g. a URL in a redacted field).
  def highlight_json(value, changed_keys: [], tone: nil)
    json = JSON.pretty_generate(value)
    lines = json.split("\n").map do |line|
      highlighted = line.gsub(JSON_TOKEN) do
        token = Regexp.last_match(0)
        escaped = ERB::Util.html_escape(token)
        content_tag :span, escaped, class: json_token_class(token)
      end

      # JSON.pretty_generate indents top-level fields exactly two spaces;
      # deeper (nested-object) keys never match here, so a diff on
      # `service.name` never mislabels an unrelated nested `name` field.
      key = line[/\A  "([^"]+)":/, 1]
      key && changed_keys.include?(key) ? content_tag(:span, highlighted.html_safe, class: "json-diff-#{tone}") : highlighted
    end
    lines.join("\n").html_safe # rubocop:disable Rails/OutputSafety -- every matched token is escaped above; unmatched JSON punctuation needs no escaping
  end

  # M5b: the badge and the words for a certificate's expiry. A dash for
  # anything with no not_after (every non-certificate entity, or a PEM that
  # would not parse) -- never a guess.
  def expiry_badge(entity)
    status = entity.expiry_status
    return content_tag(:span, "—", style: "color: var(--color-ink-faint)") unless status

    status_badge(status)
  end

  def expiry_when(entity)
    return nil unless entity.not_after

    distance = time_ago_in_words(entity.not_after)
    entity.not_after <= Time.current ? "#{distance} ago" : "in #{distance}"
  end

  # Which controllers belong to which primary-nav link. The nav names the
  # section, not the exact page, so a page inside a section keeps its link
  # marked: the login form is part of Connections; a change plan's review page,
  # the plugin catalog and the expiry dashboard are all reached from and return
  # to the Entities browser. Audit, Tokens and Health each own one controller.
  PRIMARY_NAV_CONTROLLERS = {
    connections: %w[connections sessions],
    entities: %w[entities plugins certificates change_plans],
    audit: %w[audit_events],
    tokens: %w[personal_access_tokens],
    health: %w[health]
  }.freeze

  #
  # Pending PRs is the one section that shares a controller with another: a
  # plan's review page belongs to Entities, the list of PR-mode plans to itself.
  def primary_nav_current?(section)
    on_pending_prs = controller_name == "change_plans" && action_name == "index"
    return on_pending_prs if section == :pending
    return false if section == :entities && on_pending_prs

    PRIMARY_NAV_CONTROLLERS.fetch(section).include?(controller_name)
  end

  # A nav link that says where the reader is: aria-current="page" when
  # `current` is true, and no aria-current attribute at all otherwise (never
  # aria-current="false"). The visual state hangs off that attribute
  # (`.topbar nav [aria-current]` in application.css), so sighted and
  # assistive-tech users read the same fact.
  def nav_link_to(name, path, current:, **options)
    options[:"aria-current"] = "page" if current
    link_to name, path, **options
  end

  private

  def json_token_class(token)
    if token.start_with?('"')
      token.end_with?(":") ? "json-key" : "json-string"
    elsif token == "true" || token == "false"
      "json-bool"
    elsif token == "null"
      "json-null"
    else
      "json-number"
    end
  end
end
