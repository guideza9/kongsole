# R3's shared hint pieces. Every word comes from config/locales/hints.en.yml;
# these helpers only choose which keys a view shows and how they are laid out.
module HintsHelper
  # A field's help line and example value, with the longer detail only while
  # detailed hints are on. `id` is what the input's aria-describedby points at
  # (hint_describedby builds the conventional one).
  #
  # `quiet: true` (the R2 forms): with compact hints nothing shows under the
  # field -- the example is its placeholder (hint_placeholder) and the help
  # stays for screen readers only. Detailed hints show everything, as before.
  def field_hint(form, field, id: hint_describedby(form, field), quiet: false)
    scope = "hints.fields.#{form}.#{field}"
    render "shared/field_hint", id: id, help: t("#{scope}.help"),
      example: optional_hint("#{scope}.example"),
      detail: (optional_hint("#{scope}.detail") if detailed_hints?),
      screen_reader_only: quiet && !detailed_hints?
  end

  # A field's example value, for its placeholder -- "e.g. …", so an empty
  # field never reads as a filled one.
  def hint_placeholder(form, field)
    example = optional_hint("hints.fields.#{form}.#{field}.example")
    example && "#{t('hints.ui.example_prefix')} #{example}"
  end

  def hint_describedby(form, field)
    "hint-#{form}-#{field}".tr("_", "-")
  end

  # The line under a page's heading. Compact hints (the default): only the
  # page's own facts -- a scope, a time window, the next action -- or nothing.
  # Detailed hints add the explanation from hints.pages.*.intro in front.
  def page_lede(key = nil, facts: nil, **interpolations)
    parts = [ (t(key, **interpolations) if key && detailed_hints?), facts ].compact_blank
    parts.any? ? safe_join(parts, " ") : nil
  end

  # What a page is for and how to start, when it has nothing to show yet. A
  # block supplies the page's own action (a link or button), if it has one.
  def empty_state(page, **interpolations, &action)
    scope = "hints.empty_states.#{page}"
    render "shared/empty_state", title: t("#{scope}.title", **interpolations),
      body: t("#{scope}.body", **interpolations), action: (capture(&action) if action)
  end

  # What an action will do before it is confirmed (delete, rank >= 2, admin
  # path). `tone` is the notice-banner tone: :warning by default, :danger for
  # the things that cannot be undone.
  def risk_notice(situation, tone: :warning, **interpolations)
    scope = "hints.risks.#{situation}"
    render "shared/risk_notice", tone: tone, title: t("#{scope}.title", **interpolations),
      body: t("#{scope}.body", **interpolations)
  end

  # A raw Kong schema `fields` array (a plugin's config) in the row shape
  # Kong::EntitySchema returns, so one reference partial serves both.
  def schema_rows(fields)
    Array(fields).filter_map do |field|
      name, spec = field.first
      next unless spec.is_a?(Hash)

      nested = spec["fields"] || spec.dig("elements", "fields")
      { name: name, type: spec["type"], required: spec["required"] == true, default: spec["default"],
        one_of: spec["one_of"] || spec.dig("elements", "one_of"), description: spec["description"],
        nested: nested ? schema_rows(nested) : [] }
    end
  end

  private

  def optional_hint(key)
    t(key) if I18n.exists?(key)
  end
end
