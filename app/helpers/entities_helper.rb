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
      [ "Updated", "minmax(92px, auto)" ]
    ],
    "route" => [
      [ "Name", "minmax(120px, 0.9fr)" ],
      [ "Path", "minmax(220px, 1.6fr)" ],
      [ "Tags", "minmax(120px, 0.9fr)" ],
      [ "Status", "minmax(96px, auto)" ],
      [ "Updated", "minmax(92px, auto)" ]
    ],
    "consumer" => [
      [ "Name", "minmax(160px, 1.3fr)" ],
      [ "Tags", "minmax(140px, 1fr)" ],
      [ "Status", "minmax(96px, auto)" ],
      [ "Updated", "minmax(92px, auto)" ]
    ],
    "plugin" => [
      [ "Name", "minmax(140px, 1fr)" ],
      [ "Scope", "minmax(180px, 1.4fr)" ],
      [ "Tags", "minmax(120px, 0.9fr)" ],
      [ "Status", "minmax(96px, auto)" ],
      [ "Updated", "minmax(92px, auto)" ]
    ],
    "upstream" => [
      [ "Name", "minmax(160px, 1.3fr)" ],
      [ "Algorithm", "minmax(120px, 0.8fr)" ],
      [ "Tags", "minmax(120px, 0.9fr)" ],
      [ "Status", "minmax(96px, auto)" ],
      [ "Updated", "minmax(92px, auto)" ]
    ],
    "target" => [
      [ "Target", "minmax(160px, 1.3fr)" ],
      [ "Weight", "minmax(80px, 0.5fr)" ],
      [ "Tags", "minmax(120px, 0.9fr)" ],
      [ "Status", "minmax(96px, auto)" ],
      [ "Updated", "minmax(92px, auto)" ]
    ],
    "certificate" => [
      [ "Name", "minmax(160px, 1.2fr)" ],
      [ "SNIs", "minmax(64px, 0.4fr)" ],
      [ "Expires", "minmax(200px, 1.3fr)" ],
      [ "Tags", "minmax(120px, 0.9fr)" ],
      [ "Status", "minmax(96px, auto)" ],
      [ "Updated", "minmax(92px, auto)" ]
    ],
    "ca_certificate" => [
      [ "Name", "minmax(160px, 1.2fr)" ],
      [ "Expires", "minmax(200px, 1.3fr)" ],
      [ "Tags", "minmax(120px, 0.9fr)" ],
      [ "Status", "minmax(96px, auto)" ],
      [ "Updated", "minmax(92px, auto)" ]
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
    type.in?(%w[route plugin upstream target certificate ca_certificate]) ? "820px" : "620px"
  end

  def entity_table_columns(type)
    ENTITY_TABLE_COLUMNS.fetch(type, ENTITY_TABLE_COLUMNS["service"])
  end

  # A route's one identifying fact besides its name -- method(s) + path(s)
  # straight from Kong's own (unredacted; routes carry no secrets) JSON.
  # nil for any other entity_type, so the caller can render an em dash.
  def route_path_summary(entity)
    return nil unless entity.entity_type == "route"

    methods = Array(entity.data["methods"])
    paths = Array(entity.data["paths"])
    return { methods: "ANY", path: "/" } if paths.empty? && methods.empty?

    { methods: methods.empty? ? "ANY" : methods.join(", "), path: paths.presence&.join(", ") || "/" }
  end

  # A plugin's scope -- "global", or the type and name of whichever
  # service/route/consumer it's attached to. A live lookup rather than
  # something baked in at sync time (see Kong::EntitySync#identify_plugin's
  # comment): cheap here (one row's parent, not a whole page), and it stays
  # correct even if the parent's own name changes after the plugin last
  # synced.
  def plugin_scope_label(entity)
    return "global" if entity.parent_type.blank?

    parent = KongEntity.active.find_by(kong_connection: entity.kong_connection, entity_type: entity.parent_type, kong_id: entity.parent_kong_id)
    "#{entity.parent_type}: #{parent&.name || entity.parent_kong_id[0..7]}"
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

  # The cached certificate metadata is data we parsed once and stored, not
  # something to trust: an unreadable timestamp shows a dash rather than
  # failing the whole detail page.
  def certificate_time(value)
    return "—" if value.blank?

    Time.iso8601(value).to_fs(:long)
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
end
