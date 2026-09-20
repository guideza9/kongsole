module ApplicationHelper
  # The env color tag is a functional guardrail, not decoration
  # (docs/DESIGN.md section 14: "the color tag is the cheapest, most
  # effective guardrail against touching the wrong environment") -- it must
  # render as a legible badge everywhere a connection's identity appears,
  # never as a small decorative dot easy to miss under pressure. Rendered as
  # a flat dot + label chip (docs/UI-DESIGN.md) rather than a lit lamp.
  COLOR = {
    "red" => { dot: "#a3312a", bg: "#f8ecea", text: "#6e2015" },
    "orange" => { dot: "#a3611c", bg: "#f6ede0", text: "#6b3c0f" },
    "yellow" => { dot: "#93600f", bg: "#f7efe0", text: "#5c4a14" },
    "green" => { dot: "#2f6b45", bg: "#ecf3ec", text: "#1e3a21" },
    "gray" => { dot: "#6c6c67", bg: "#f0f0ee", text: "#3a3a36" }
  }.freeze

  def connection_color_hex(color_tag)
    COLOR.fetch(color_tag.to_s, COLOR["gray"])[:bg]
  end

  # A solid, bordered env badge -- the primary "which environment am I
  # looking at" signal, sized to be read at a glance, not squinted at.
  def env_badge(connection, size: :md)
    colors = COLOR.fetch(connection.color_tag.to_s, COLOR["gray"])
    classes = size == :lg ? "chip chip-lg" : "chip"
    dot = content_tag :span, "", class: "chip-dot", style: "color:#{colors[:dot]}"
    content_tag :span, dot + connection.name,
      class: classes,
      style: "background-color:#{colors[:bg]}; color:#{colors[:text]}"
  end

  STATUS_TONE = {
    "ok" => { dot: "#2f6b45", bg: "#ecf3ec", text: "#1e3a21" },
    "unauthorized" => { dot: "#a3312a", bg: "#f8ecea", text: "#6e2015" },
    "forbidden" => { dot: "#a3312a", bg: "#f8ecea", text: "#6e2015" },
    "route_not_matched" => { dot: "#93600f", bg: "#f7efe0", text: "#5c4a14" },
    "not_found" => { dot: "#a3312a", bg: "#f8ecea", text: "#6e2015" },
    "rate_limited" => { dot: "#93600f", bg: "#f7efe0", text: "#5c4a14" },
    "unavailable" => { dot: "#a3312a", bg: "#f8ecea", text: "#6e2015" },
    "error" => { dot: "#a3312a", bg: "#f8ecea", text: "#6e2015" }
  }.freeze
  STATUS_TONE_DEFAULT = { dot: "#6c6c67", bg: "#f0f0ee", text: "#3a3a36" }.freeze

  def status_label(status)
    (status || "never connected").to_s.humanize
  end

  ENTITY_TYPE_LABELS = {
    "service" => %w[Service Services],
    "route" => %w[Route Routes],
    "consumer" => %w[Consumer Consumers],
    "keyauth_credential" => %w[Key-auth\ credential Key-auth\ credentials],
    "basicauth_credential" => %w[Basic-auth\ credential Basic-auth\ credentials],
    "plugin" => %w[Plugin Plugins],
    "upstream" => %w[Upstream Upstreams],
    "target" => %w[Target Targets]
  }.freeze

  def entity_type_label(entity_type, count: nil)
    singular, plural = ENTITY_TYPE_LABELS.fetch(entity_type.to_s, [ entity_type.to_s.humanize, entity_type.to_s.humanize.pluralize ])
    count.nil? ? plural : (count == 1 ? singular : plural)
  end

  def status_badge(status)
    tone = STATUS_TONE.fetch(status.to_s, STATUS_TONE_DEFAULT)
    dot = content_tag :span, "", class: "chip-dot", style: "color:#{tone[:dot]}"
    content_tag :span, dot + status_label(status),
      class: "chip",
      style: "background-color:#{tone[:bg]}; color:#{tone[:text]}"
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
