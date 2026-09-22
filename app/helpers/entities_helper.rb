module EntitiesHelper
  # entities#index's table columns, per entity_type -- each column's
  # [label, grid track]. Route gets a Path column (its one identifying
  # fact besides name). Status stays on every type, including consumer --
  # it carries the admin-path "protected" guardrail (docs/DESIGN.md section
  # 15 M3: "a consumer holding an admin-path credential can never be
  # deleted"), which matters regardless of whether the type also has an
  # `enabled` concept; the cell itself (_entity_row.html.erb) is what skips
  # the disabled tag for a type with no `enabled` field.
  ENTITY_TABLE_COLUMNS = {
    "service" => [
      [ "Name", "minmax(160px, 1.3fr)" ],
      [ "Tags", "minmax(140px, 1fr)" ],
      [ "Status", "minmax(96px, auto)" ],
      [ "Updated", "minmax(180px, auto)" ]
    ],
    "route" => [
      [ "Name", "minmax(120px, 0.9fr)" ],
      [ "Path", "minmax(220px, 1.6fr)" ],
      [ "Tags", "minmax(120px, 0.9fr)" ],
      [ "Status", "minmax(96px, auto)" ],
      [ "Updated", "minmax(180px, auto)" ]
    ],
    "consumer" => [
      [ "Name", "minmax(160px, 1.3fr)" ],
      [ "Tags", "minmax(140px, 1fr)" ],
      [ "Status", "minmax(96px, auto)" ],
      [ "Updated", "minmax(180px, auto)" ]
    ],
    "plugin" => [
      [ "Name", "minmax(140px, 1fr)" ],
      [ "Scope", "minmax(180px, 1.4fr)" ],
      [ "Tags", "minmax(120px, 0.9fr)" ],
      [ "Status", "minmax(96px, auto)" ],
      [ "Updated", "minmax(180px, auto)" ]
    ],
    "upstream" => [
      [ "Name", "minmax(160px, 1.3fr)" ],
      [ "Algorithm", "minmax(120px, 0.8fr)" ],
      [ "Tags", "minmax(120px, 0.9fr)" ],
      [ "Status", "minmax(96px, auto)" ],
      [ "Updated", "minmax(180px, auto)" ]
    ],
    "target" => [
      [ "Target", "minmax(160px, 1.3fr)" ],
      [ "Weight", "minmax(80px, 0.5fr)" ],
      [ "Tags", "minmax(120px, 0.9fr)" ],
      [ "Status", "minmax(96px, auto)" ],
      [ "Updated", "minmax(180px, auto)" ]
    ],
    "certificate" => [
      [ "Name", "minmax(160px, 1.2fr)" ],
      [ "SNIs", "minmax(64px, 0.4fr)" ],
      [ "Expires", "minmax(200px, 1.3fr)" ],
      [ "Tags", "minmax(120px, 0.9fr)" ],
      [ "Status", "minmax(96px, auto)" ],
      [ "Updated", "minmax(180px, auto)" ]
    ],
    "ca_certificate" => [
      [ "Name", "minmax(160px, 1.2fr)" ],
      [ "Expires", "minmax(200px, 1.3fr)" ],
      [ "Tags", "minmax(120px, 0.9fr)" ],
      [ "Status", "minmax(96px, auto)" ],
      [ "Updated", "minmax(180px, auto)" ]
    ]
  }.freeze

  def entity_table_headers(type)
    entity_table_columns(type).map(&:first)
  end

  def entity_table_grid_columns(type)
    entity_table_columns(type).map(&:last).join(" ")
  end

  # Wide enough that every column's minmax floor fits without crushing —
  # the table scrolls horizontally below this, the same pattern already
  # used by audit_events/change_plans' tables.
  def entity_table_min_width(type)
    type.in?(%w[route plugin upstream target certificate ca_certificate]) ? "910px" : "710px"
  end

  def entity_table_columns(type)
    ENTITY_TABLE_COLUMNS.fetch(type, ENTITY_TABLE_COLUMNS["service"])
  end

  # What a route matches on, straight from Kong's own (unredacted; routes
  # carry no secrets) JSON: methods, hosts and paths, each a list. An empty
  # methods list means every method. nil for any other entity_type.
  def route_match(entity)
    return nil unless entity.entity_type == "route"

    { methods: Array(entity.data["methods"]), hosts: Array(entity.data["hosts"]), paths: Array(entity.data["paths"]) }
  end

  # The service a route forwards to -- the read-model row, so the page can
  # link to it. nil when the route has none, or it has not been synced yet.
  def route_service(entity)
    id = entity.data.dig("service", "id") if entity.data["service"].is_a?(Hash)
    return nil if id.blank?

    KongEntity.active.find_by(kong_connection: entity.kong_connection, entity_type: "service", kong_id: id)
  end

  # A plugin's scope -- :global, or the type and name of whichever
  # service/route/consumer it's attached to. A live lookup rather than
  # something baked in at sync time (see Kong::EntitySync#identify_plugin's
  # comment): cheap here (one row's parent, not a whole page), and it stays
  # correct even if the parent's own name changes after the plugin last
  # synced.
  def plugin_scope(entity)
    return { kind: "global" } if entity.parent_type.blank?

    parent = KongEntity.active.find_by(kong_connection: entity.kong_connection, entity_type: entity.parent_type, kong_id: entity.parent_kong_id)
    { kind: entity.parent_type, name: parent&.name || entity.parent_kong_id.to_s[0..7], entity: parent }
  end

  # The one sentence a plugin's page owes the reader: how far it reaches.
  def plugin_scope_sentence(scope)
    case scope[:kind]
    when "global" then "Runs on every request through this Kong, unless a narrower plugin of the same kind takes over."
    when "service" then "Runs on every request to this service."
    when "route" then "Runs on requests that match this route."
    when "consumer" then "Runs on requests made by this consumer."
    else "Runs within this #{scope[:kind]}."
    end
  end

  # The hostnames a certificate answers for: the SANs parsed from the PEM at
  # sync time, else the SNIs Kong lists. Two are shown on a list row and the
  # rest counted, so every row holds one line.
  MAX_INLINE_HOSTNAMES = 2

  def certificate_hostnames(entity)
    meta = entity.data["_metadata"] || {}
    names = Array(meta["sans"]).presence || Array(entity.data["snis"])
    { shown: names.first(MAX_INLINE_HOSTNAMES), more: [ names.size - MAX_INLINE_HOSTNAMES, 0 ].max }
  end

  # How much of a certificate's validity has gone: the fraction between
  # not_before and not_after that has passed, and the tone the expiry badge
  # already gives it. nil when either end is unknown -- never a guess.
  LIFESPAN_TONES = { "ok" => "ok", "warning" => "warning", "critical" => "danger", "expired" => "danger" }.freeze

  def certificate_lifespan(entity, now = Time.current)
    from = parse_iso_time((entity.data["_metadata"] || {})["not_before"])
    to = entity.not_after
    return nil unless from && to && to > from

    elapsed = ((now - from) / (to - from)).clamp(0.0, 1.0)
    { percent: (elapsed * 100).round, tone: LIFESPAN_TONES.fetch(entity.expiry_status(now), "ok"), from: from, to: to }
  end

  # What the certificate page says about a certificate's private key: the
  # reference and the env var it reads, "plaintext" when Kong still holds one
  # (the redactor blanked it -- this tool never sets one), or nil.
  def certificate_key_summary(entity)
    key = entity.data["key"]
    if Kong::CertificateKeyPolicy.vault_reference?(key)
      { kind: :reference, value: key, env_var: Kong::CertificateKeyPolicy.env_var_name(key) }
    elsif key == Kong::Redactor::MARK
      { kind: :plaintext }
    end
  end

  # How old the read-model may be before the list says so in warning ink.
  # There is no scheduled sync yet, so this is the point past which an
  # operator should not trust the rows to match Kong without pressing Sync now.
  SYNC_STALE_AFTER = 1.hour

  # The freshness sentence beside "Sync now" on entities#index. `synced_at` is
  # the *oldest* row's sync time (see EntitiesController#index): a write-through
  # sync_one after an apply refreshes one row, and must not make the rest of the
  # list look newer than it is. Staleness is said in words as well as tone.
  def sync_freshness(synced_at, connection_name)
    return tag.span("Never synced from #{connection_name}. Sync to list what's in Kong.") if synced_at.blank?

    age = tag.time("#{time_ago_in_words(synced_at)} ago",
      datetime: synced_at.getutc.iso8601, title: synced_at.getutc.strftime("%Y-%m-%d %H:%M:%S UTC"))
    stale = synced_at < SYNC_STALE_AFTER.ago
    tag.span(class: ("text-warning" if stale)) do
      safe_join([ "Synced from #{connection_name} ", age, (stale ? ", so it may be out of date." : ".") ])
    end
  end

  # The cached certificate metadata is data we parsed once and stored, not
  # something to trust: an unreadable timestamp shows a dash rather than
  # failing the whole detail page.
  def certificate_time(value)
    return "—" if value.blank?

    plan_timestamp(Time.iso8601(value))
  rescue ArgumentError, TypeError
    "—"
  end

  # Caps a row to one line of tags so every row holds the same height --
  # a long tag list wrapping to two or three lines breaks the table's
  # rhythm far worse than a "+N" overflow marker does.
  MAX_INLINE_TAGS = 3

  def visible_tags(entity)
    entity.tags.first(MAX_INLINE_TAGS)
  end

  # "ca_certificate" reads badly in a heading; every other creatable type's
  # raw name is already fine.
  def creatable_type_name(type)
    { "ca_certificate" => "CA certificate" }.fetch(type.to_s, type.to_s)
  end

  def hidden_tag_count(entity)
    [ entity.tags.size - MAX_INLINE_TAGS, 0 ].max
  end

  private

  def parse_iso_time(value)
    Time.iso8601(value) if value.present?
  rescue ArgumentError, TypeError
    nil
  end
end
