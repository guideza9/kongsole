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
| Border strong | `--color-border-strong` | `#8b8b84` | Input/button borders (>= 3:1 on bg, surface, surface-subtle) |
| Ink | `--color-ink` | `#18181a` | Primary text, primary button fill |
| Ink soft | `--color-ink-soft` | `#6c6c67` | Secondary text |
| Ink faint | `--color-ink-faint` | `#6f6f69` | Tertiary/meta text (>= 4.5:1 on bg, surface, surface-subtle) |
| Accent | `--color-accent` / `-strong` / `-tint` | `#3c5a78` / `#2c4460` / `#eaeff3` | Focus ring, primary button hover, selection |
| Danger | `--color-danger` / `-tint` | `#a3312a` / `#f8ecea` | Errors, expired items, destructive actions, removed-diff values, a live (direct-mode) write at rank >= 2. Never an environment's identity. |
| Success | `--color-success` / `-tint` | `#2f6b45` / `#ecf3ec` | Ok status, success notices |
| Warning | `--color-warning` / `-tint` | `#93600f` / `#f7efe0` | Warn-tier status |
| Environment | `--color-env-uat` / `-prod` / `-on` / `-uat-tint` / `-prod-tint` | `#8a3b86` / `#3b2a78` / `#ffffff` / `#f6ebf5` / `#efebf7` | Identity of a protected environment (rank >= 2): topbar rule, solid chip, plan strip, consequence panel, PR-mode submit button. Plum (uat) and deep indigo (prod), never red: red means error, and prod is not an error. |
| Chip tones | `--color-success-ink`, `-danger-ink`, `-warning-ink`, `--color-caution` / `-tint` / `-ink`, `--color-neutral-tint` / `-ink` | see `application.css` | The label ink (and, for caution and neutral, the tint) behind `.chip-ok` / `-danger` / `-warning` / `-caution` / `-neutral`. `ApplicationHelper` only picks the tone; it holds no hex. |

**Quiet at dev/sit, loud at uat/prod.** Loudness follows rank, so a screen
only shouts where a wrong click is expensive. Below rank 2 (dev/sit, direct
apply) nothing is added: the flat dot + tint chip, the ink `.btn-primary`, no
strip, no retype. At rank >= 2 (uat/prod, PR mode) the same surfaces turn a
solid violet, all reading one `--env` variable so they cannot disagree:

| Surface | dev / sit (rank 0-1) | uat / prod (rank >= 2) |
|---|---|---|
| Topbar | plain hairline | `--env` top rule: 6px solid for uat, 9px double for prod (`.topbar.env-*`) |
| Env chip | flat dot + tint (`color_tag`) | solid `--env` fill, "PROD · name" / "UAT · name" (name dropped when it is only the env), round dot for uat, square for prod (`.chip-env`) |
| Plan review header | none | `.env-strip`: "PROD · PR mode → branch kongctl/…" |
| Consequence copy | none | `.env-notice` above the submit button |
| Confirm | none | retype the connection name; submit locked until it matches |
| Submit button | `.btn-primary` (ink) | `.btn-env` (PR push), `.btn-danger` only for a live direct write |

uat is a plum (`#8a3b86`), prod a deep indigo (`#3b2a78`): a hue apart, not
just a shade, and told apart by more than colour. The chip says UAT or PROD,
the topbar rule is solid for uat and double for prod, and the chip dot is
round or square. Those cues are borders, text and shape, so they survive
forced-colors mode (`@media (forced-colors: active)` keeps the chip and strip
as outlined containers, prod with a heavier double line). Both colours hold
white text at >= 4.5:1 (6.9:1 and 11.7:1), and a spec keeps them >= 30 degrees
of hue apart. The tone is chosen by
rank (`KongConnection#env_tone`), never by `color_tag`, so a mis-tagged prod
connection cannot lose it. Red stays reserved for errors and true destruction:
prod is a place to be careful, not a failure state.

### Kong-native marks

The console's chrome is generic on purpose; the things Kong is made of are
not. Four marks give them an identity, each built from pieces the console
already owns (hairlines, mono for data, the status tones) so none of them
adds a colour, a font or an icon set. All read without colour, and all hold in
forced-colors mode.

| Mark | Where | What it says |
|---|---|---|
| Request line (`.route-match`) | routes list, route page | A route is what it matches: bordered mono method chips (`ANY` when there are none), the hosts, then the paths, each path bold mono with a `~` in the accent when it is a regex. The route page adds where it forwards to (linked) and how it behaves. |
| Scope (`.scope`) | plugins list, plugin page | A plugin is how far it reaches. Scoped: a hairline box holding the kind (`SERVICE`) and the name. Global: the one solid ink mark in the list, because it touches every request. The plugin page states the reach in a sentence. |
| Lifespan (`.lifespan`) | certificate page | How much of a certificate's validity has passed: a track filled to the elapsed fraction, in the expiry badge's tone, with the two dates at its ends. The list carries the hostnames the certificate answers for under its name (SANs, else SNIs). |
| Admin path (`.entity-row--admin`, `.admin-path-notice`) | every entity list, entity page | The one entity Kongsole cannot lose. The row takes the warning tint (a fill, not a stripe) and a lock chip that says "admin path"; the page opens with a notice that names what it means: never deletable by an agent, name typed to delete here, left out of decK YAML. A plugin on the admin path says it is read-only instead. |

Color strategy: restrained — neutrals carry the page, one accent (steel
blue) for focus/primary emphasis. Environment/status color tags stay the
functional guardrail they always were (`docs/DESIGN.md` §14, "the color tag
is the cheapest, most effective guardrail against touching the wrong
environment") — flat dot + label chip below rank 2, solid violet chip and
chrome at rank >= 2 (`ApplicationHelper#env_badge` / `#status_badge`), never
decoration alone.

## Type

A single sans (`--font-sans`, Public Sans) throughout — headings, body,
labels, buttons — differentiated by weight and size, not by a second
display face. `--font-mono` (JetBrains Mono) is used only where the value is
genuinely data: admin URLs, tags, ids, `select_tags`.

Loaded via Google Fonts in `app/views/layouts/application.html.erb`.

Three roles, three sizes, all set in `application.css`:

| Role | Size | Where |
|---|---|---|
| Page title (`.page-title`) | 24px, 700, -0.015em, balanced | the one `h1` on every page |
| Body (`text-sm`) | 14px | what people read and edit: rows, forms, sentences, gate labels |
| Small (`text-xs`) | 13px | metadata, section labels, hints, chips, tags, guardrail verdicts |

13px is the floor. `--text-xs` is 13px, not Tailwind's 12, so every `text-xs`
and every custom rule that uses `var(--text-xs)` holds it, and a spec fails if
a rule under the floor comes back. The gate labels in the action bar are the
one instruction the commit turns on, so they are body size, not small.

## One dialect

The same thing is said the same way everywhere, and specs read the rendered
pages to keep it so (`spec/requests/consistency_spec.rb`):

- **Times.** Every absolute time is `plan_timestamp`: `YYYY-MM-DD HH:MM` in the
  viewer's zone (UTC with JS off), in lists, detail pages, tokens, health and
  audit alike. Relative phrases ("in 12 days") sit beside it, never instead.
- **States.** A state is a `status_badge` (Ok, Applied, Failed, Revoked, Guarded,
  Unknown, ...), whose tone the stylesheet owns. No page colours a bare word.
- **Choosing one of a few.** Entity types, the expiry window and the upstream
  starting point are all `.tab` in a `.tab-nav`, the current one marked by
  `aria-current` alone.
- **Where things are.** Pending PRs is in the primary nav (current on the plan
  list, not on a plan's review page, which belongs to Entities), and Health lists
  Log in and Details on every connection.

## Targets and structure

- **Topbar targets.** The primary nav, Switch and Sign out share `.topbar-action`:
  14px text, 36px tall for a mouse and 44px for a coarse pointer
  (`@media (pointer: coarse)`), with a hover fill so the whole target shows. The
  bar keeps its height on desktop because the padding it spent now lives in the
  targets. Below 40rem it is not sticky (it is three rows of 44px targets), and
  the env chip truncates its name so the header stays at three rows.
- **The entity list is a table.** `entities#index` is `role="table"` with a
  `columnheader` per column and a `row` of `cell`s per entity, so a screen reader
  announces columns and headers. The row is not the link: the name is, and its
  `::after` covers the row (`.entity-link`), so the whole row is still the click
  target and keyboard focus rings the whole row (`.entity-row:has(.entity-link:focus-visible)`).

## Components (`app/assets/tailwind/application.css`)

- `.topbar` — header: white surface, single hairline bottom border. No
  chassis, no gradient.
- `.wordmark` — plain bold text mark ("Kongsole") in the header.
- `.panel` — grouped content (forms, detail sections, empty states):
  surface + hairline border, no shadow.
- `.row-card` — a connection's row in the index: same as `.panel`, border
  darkens slightly on hover.
- `.chip` / `.chip-lg` / `.chip-dot` — env/status badges: a small solid dot
  in the semantic color plus a label on a light tint background. At rank >= 2
  the env chip is instead solid violet with white uppercase text (`.chip-env`).
- `.env-uat` / `.env-prod` — set `--env` for everything inside. Used by
  `.topbar` (6px top rule), `.chip-env` (solid chip), `.env-strip` (the
  solid-colour Target cell of change_plans/show's summary strip: "PROD · PR
  mode → branch kongctl/…"), `.env-notice` (consequence copy; the prod login
  warning), `.action-bar` (3px top rule) and `.btn-env` (the PR-mode "Push
  branch" button). `.btn-danger` is true red and only for a live direct-mode
  write at rank >= 2.
- `.tag` — small metadata pill (apply mode, access, credential kind).
- `.btn` / `.btn-sm` — size modifiers only: inline-flex, 0.875rem text,
  padding `0.5rem 0.875rem` / `0.375rem 0.75rem` (the compact one, for dense
  rows and toolbars). They carry no color; the role class supplies it, so a
  button is always a pair: `class="btn btn-primary"`, `class="btn-sm
  btn-secondary"`. A global `button:not(:disabled) { cursor: pointer }`
  covers every button.
- `.btn-primary` — solid ink button, white text; the one filled action per
  view. At rank >= 2 the apply/push button is `.btn-env` (or `.btn-danger` for
  a live direct write) in its place, so it is still the one filled action.
- `.btn-secondary` — outlined button (border + white fill) for secondary
  actions (Edit on a detail page, a row's Log in, Filter).
- `.btn-text-danger` / `.btn-text` — plain text actions (Remove, Sign out,
  Back, and Edit inside a dense list row).
- `.field-input` — form inputs; focus ring uses the accent color.
- `.section-label` — small caps label for form/detail section headers.
- `.notice-banner` — flash/notice/warning banner (tint background, semantic
  border/text color), toned by `.notice-banner--danger|warning|success`. Never
  hand-written: every flash, warning and failure banner (the layout's
  notice/alert flashes too) goes through the `shared/_notice` partial,
  `render layout: "shared/notice", locals: { tone:, role:, tag:, class: } do … end`.
  `role` is optional (omit for a static banner), `tag` defaults to `:div`
  (`:p` for plain-text copy), `class` appends extra classes.
- `.failure-reason` — verbatim output from Kong, decK or git inside a notice
  banner: monospace, tinted from the banner's own `currentColor`, wrapping
  rather than scrolling so a reason is never half-hidden. Only ever fed
  `ChangePlan#failure_reason`, which the applier scrubs of key material
  before storing.

### Conventions

- **Tokens reach markup as Tailwind utilities**, generated from `@theme`
  (`text-ink`, `text-ink-soft`, `text-ink-faint`, `text-danger`,
  `bg-danger-tint`, `border-border`, `accent-accent`, …), never as inline
  `style="…var(--color-…)"`. `spec/views/no_inline_token_styles_spec.rb`
  enforces it. A dynamic value with no token (the entity list's
  `--entity-cols`) may stay inline.
- **Component classes are unlayered, so they beat Tailwind's layered
  utilities.** When an element carries a component class that already sets the
  same property, use the important suffix: `text-danger!`, `border-danger!`,
  `rounded-none!` (the `.tag` "required"/"revoked" pills, the `.chip-dot`
  svg).
- **One filled action per view.** The header's "Add connection" / "New …" is
  that view's one `.btn-primary`; per-row and toolbar actions are
  `.btn-secondary` (the connections index's per-row "Log in", the entities
  index's "Filter"). The one exception is entities/edit, which has two
  Review-change forms (Fields / Full JSON), each with its own submit.
- **Table header cells carry `scope="col"`** (audit events, change plans
  index, expiring certificates, health).
- **The product is "Kongsole"** everywhere it is named: title fallback,
  `application-name`, the wordmark.

### Review page (change_plans/show)

Reading order is: title → summary strip → Changes table → Guardrails →
Raw JSON → action bar. Nothing on it is a card grid; the strip is one
hairline-divided band.

- `.plan-summary` / `.plan-summary__cell` — the four-cell strip: Target
  (env + apply mode; at rank >= 2 the cell is `.env-strip`, solid `--env`),
  Changes (field count), Guardrails (what still needs the operator; only on
  a live pending plan), Expiry (countdown + stamp, or the plan's final
  status once it is no longer pending). Cells reflow 4 → 2 → 1 columns; the
  1px gap on a border-coloured ground draws the dividers.
- Absolute timestamps (the byline's "Proposed …", the applied/pushed/failed
  banners, the expiry stamp) all go through `ChangePlansHelper#plan_timestamp`:
  a `<time>` rendered server-side as `YYYY-MM-DD HH:MM UTC`, with the exact
  instant in `title`. The `local_time` Stimulus controller then rewrites the
  text in the viewer's own zone, assembling it from `Intl` parts so the
  `YYYY-MM-DD HH:MM` shape holds and only the zone changes — a locale's own
  punctuation ("21/09/2026, 19:21") would otherwise drop a comma into copy
  like "Pushed &lt;time&gt; to branch". With JS off the UTC text stands.
- Environment names in consequence copy (the password gate, its guardrail
  row, "This writes to … now", "nothing in … changes yet") are spelled out
  by `ApplicationHelper#env_display_name` — Production, UAT, SIT,
  Development. The raw `env` token stays wherever it is the identifier being
  configured: the `.env-strip` value, the connections index/show and form.
- `.diff-table` — a real `<table>`: field names are row headers, columns are
  From / To (update), New value (create) or Removed value (delete), so the
  side of a change is carried by the column, not colour alone. Inside a
  `.diff-table-wrap` (focusable scroll region) with a 30rem minimum.
- `.guardrail-list` / `.guardrail` — one row per check, state named in words
  (`Clear` / `Confirm` / `Review`) beside its dot. Built by
  `ChangePlansController#guardrails_for` from the same flags the apply path
  enforces; never a check the server does not make.
- `.disclosure` — native `<details>` restyled (border-drawn chevron). Raw
  JSON and the deck gateway diff live in one `.panel`, collapsed by default.
- `.action-bar` — the apply form, `position: sticky; bottom: 0`. The retype /
  password / typed-name inputs live in it, so a gate and the button it
  unlocks are on screen together. Capped at 60vh and scrollable; with no
  gate it says what Apply will do instead. The certificate env-var
  acknowledgement sits in Guardrails but belongs to this form via
  `form="apply-plan-form"`.
- `.json-block` — a standalone JSON `<pre>` (padding matches the 0.75rem the
  `.json-diff-*` line highlights bleed into). `.json-viewer` alone is the
  editor overlay's base, so it carries no box of its own.

## Copy register

Plain, direct labels ("Connections," "Add connection," "Log in," "Sign
out," "Edit," "Remove") carry the minimalist register; politeness lives in
the sentences that matter — the production warning ("Please take a moment
to double-check you meant to connect here before continuing"), the delete
confirmation, and field help text — which stay specific and considerate
rather than curt.

## Views covered

`app/views/layouts/application.html.erb`, `connections/index`, `show`,
`_form` (new/edit), `sessions/new`, `health/show`, `change_plans/show`
(summary strip, diff table, guardrail list, collapsed raw JSON, sticky action
bar with the retyped connection name at rank >= 2), `change_plans/index`,
`entities/index`, `new`, `edit`, `show` (with `_entity_row` and
`_certificate_details`), `plugins/new`, `certificates/expiring`,
`audit_events/index`, `personal_access_tokens/index` and `new`, and the
`shared/_notice` partial, plus the badge helpers in
`app/helpers/application_helper.rb`.

## Open for future milestones

M1+ views beyond those covered above (decK diff views, drift dashboards; see
`docs/DESIGN.md` §15) inherit this system —
dot-chips for entity/drift status, `.panel` for detail views, `.btn-primary`
for the one primary action per view — rather than introducing a new visual
language.
