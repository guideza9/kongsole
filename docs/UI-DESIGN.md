# Kongsole — UI design system

<!-- impeccable:design-schema 1 -->

This documents the app's *visual* language (chrome, color, type, components).
It is separate from `docs/DESIGN.md`, which is the solution design (data
model, API contract, security model, milestone plan) and is not a visual
reference.

## Direction

**Quiet minimalism.** Near-white ground, near-black ink, one restrained
steel-blue accent, hairline borders instead of panels-with-shadow or
ornament. This is an Operate-mode surface — task and state legibility
outrank expression, so the visual language stays out of the way of Kong
data. "Polite" is carried in the copy register, not in ornament: considerate
confirmation and warning copy (the production warning, the delete
confirmation) stays gentle and specific rather than terse or alarming.

This replaces the app's first visual pass, a retro telephone-switchboard
console (walnut/brass chassis, ledger paper, lamp badges). That world is
retired; nothing here inherits its class names or tokens.

The direction was pinned directly by product request ("Minimalist style but
still polite") rather than chosen from a concept tournament.

## Palette

| Role | Token | Hex | Use |
|---|---|---|---|
| Page background | `--color-bg` | `#fdfdfc` | Body |
| Surface | `--color-surface` | `#ffffff` | Panels, cards, inputs |
| Surface subtle | `--color-surface-subtle` | `#f5f5f3` | Tags, table header row, hover fill |
| Border | `--color-border` | `#e3e3df` | Hairline dividers |
| Border strong | `--color-border-strong` | `#cbcbc5` | Input/button borders |
| Ink | `--color-ink` | `#18181a` | Primary text, primary button fill |
| Ink soft | `--color-ink-soft` | `#6c6c67` | Secondary text |
| Ink faint | `--color-ink-faint` | `#9a9a93` | Tertiary/meta text |
| Accent | `--color-accent` / `-strong` / `-tint` | `#3c5a78` / `#2c4460` / `#eaeff3` | Focus ring, primary button hover, selection |
| Danger | `--color-danger` / `-tint` | `#a3312a` / `#f8ecea` | Prod warnings, destructive actions, error banners |
| Success | `--color-success` / `-tint` | `#2f6b45` / `#ecf3ec` | Ok status, success notices |
| Warning | `--color-warning` / `-tint` | `#93600f` / `#f7efe0` | Warn-tier status |

Color strategy: restrained — neutrals carry the page, one accent (steel
blue) for focus/primary emphasis. Environment/status color tags stay the
functional guardrail they always were (`docs/DESIGN.md` §14, "the color tag
is the cheapest, most effective guardrail against touching the wrong
environment") — rendered as a small flat dot + label chip
(`ApplicationHelper#env_badge` / `#status_badge`), never decoration alone.

## Type

A single sans (`--font-sans`, Public Sans) throughout — headings, body,
labels, buttons — differentiated by weight and size, not by a second
display face. `--font-mono` (JetBrains Mono) is used only where the value is
genuinely data: admin URLs, tags, ids, `select_tags`.

Loaded via Google Fonts in `app/views/layouts/application.html.erb`.

## Components (`app/assets/tailwind/application.css`)

- `.topbar` — header: white surface, single hairline bottom border. No
  chassis, no gradient.
- `.wordmark` — plain bold text mark ("Kongsole") in the header.
- `.panel` — grouped content (forms, detail sections, empty states):
  surface + hairline border, no shadow.
- `.row-card` — a connection's row in the index: same as `.panel`, border
  darkens slightly on hover.
- `.chip` / `.chip-lg` / `.chip-dot` — env/status badges: a small solid dot
  in the semantic color plus a label on a light tint background.
- `.tag` — small metadata pill (apply mode, access, credential kind).
- `.btn-primary` — solid ink button, white text; the one filled action per
  view.
- `.btn-secondary` — outlined button (border + white fill) for secondary
  actions (Edit).
- `.btn-text-danger` / `.btn-text` — plain text actions (Remove, Sign out,
  Back).
- `.field-input` — form inputs; focus ring uses the accent color.
- `.section-label` — small caps label for form/detail section headers.
- `.notice-banner` — flash/notice/warning banner (tint background, semantic
  border/text color).

## Copy register

Plain, direct labels ("Connections," "Add connection," "Log in," "Sign
out," "Edit," "Remove") carry the minimalist register; politeness lives in
the sentences that matter — the production warning ("Please take a moment
to double-check you meant to connect here before continuing"), the delete
confirmation, and field help text — which stay specific and considerate
rather than curt.

## Views covered

`app/views/layouts/application.html.erb`, `connections/index`, `show`,
`_form` (new/edit), `sessions/new`, `health/show`, plus the badge helpers in
`app/helpers/application_helper.rb`.

## Open for future milestones

M1+ will add the entity browser, decK diff views, plugin config forms, and
drift dashboards (see `docs/DESIGN.md` §15). Those inherit this system —
dot-chips for entity/drift status, `.panel` for detail views, `.btn-primary`
for the one primary action per view — rather than introducing a new visual
language.
