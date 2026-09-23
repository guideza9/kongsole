# UI polish — app/views Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove visual-system drift across every view in `app/views` (inline token styles, hand-repeated banners and button sizing, more than one filled primary per view, unscoped table headers, product-name inconsistency) without changing behavior, tokens, fonts, colors or factual copy.

**Architecture:** Tokens already live in Tailwind 4 `@theme`, so `text-ink-soft`, `bg-danger-tint`, `border-border`, etc. already exist as utilities. About 190 inline `style="…var(--color-…)"` attributes become those utilities. Repeated banners become one `shared/_notice` partial backed by `.notice-banner--{danger,warning,success}`. Button padding/size moves into `.btn` / `.btn-sm`. A regression spec keeps inline token styles from coming back.

**Tech Stack:** Rails 8, ERB, Tailwind 4 (`app/assets/tailwind/application.css`), Stimulus, RSpec (request specs + Nokogiri).

**Spec:** the approved design in chat (2026-09-21, "polish all of app/views"), the critique `.impeccable/critique/2026-09-21T10-42-02Z__app-views.md`, and the design system `docs/UI-DESIGN.md` (there is no root DESIGN.md; `docs/DESIGN.md` is the solution design, not visual).

## Global Constraints

- **No new or changed design tokens, fonts, or colors.** Only what `docs/UI-DESIGN.md` lists. New CSS is component classes built from existing tokens (CLAUDE.md).
- **No behavior, route, controller, or model changes.** View/CSS/doc/spec only.
- **No copy-claim changes.** Wording stays, except the product-name fix in Task 5. `rank N` copy stays.
- **One filled primary action per view** (`.btn-primary`, or `.btn-env`/`.btn-danger` at rank >= 2 on the plan page).
- **Do not touch** `change_plans/show.html.erb` logic, `.env-*`, `.plan-summary`, `.action-bar`, `.guardrail*`, `.diff-table` behavior. Only replace inline styles and banners there.
- **Uncommitted work already on this branch must be preserved.** Do not `git stash`, `git checkout --`, or `git reset`. Commit only the files you changed, by explicit path (`git add <paths>`), never `git add -A`.
- **After any CSS change, rebuild** Tailwind (`bin/rails tailwindcss:build`) before judging a screenshot.
- Every task below names the `/impeccable` command whose reference the implementer follows.

## File Structure

| File | Responsibility |
|---|---|
| `app/assets/tailwind/application.css` | Add `.btn`, `.btn-sm`, `.notice-banner--*`, global button cursor. No tokens. |
| `app/views/shared/_notice.html.erb` (new) | One banner: `render layout: "shared/notice", locals: { tone:, role: }` with block content. |
| `spec/views/no_inline_token_styles_spec.rb` (new) | Regression guard: no `var(--color-…)` inside a `style` in any view. |
| `spec/requests/connections_spec.rb` (create or extend) | One filled primary per index page. |
| `spec/requests/accessibility_spec.rb` | Extend: `th scope="col"`. |
| `docs/UI-DESIGN.md` | Document new components and the M1+ views. |

**Conversion table** (used by Tasks 2–5; apply by merging into the element's existing `class`, removing the `style` attribute):

| Inline style | Replacement classes |
|---|---|
| `color: var(--color-ink)` | `text-ink` |
| `color: var(--color-ink-soft)` | `text-ink-soft` |
| `color: var(--color-ink-faint)` | `text-ink-faint` |
| `color: var(--color-danger\|success\|warning)` | `text-danger` / `text-success` / `text-warning` |
| `border-bottom: 1px solid var(--color-border)` | `border-b border-border` |
| `border-top: 1px solid var(--color-border)` | `border-t border-border` |
| `border-left: 1px solid var(--color-border)` | `border-l border-border` |
| `background: var(--color-surface-subtle)` | `bg-surface-subtle` |
| `background(-color): var(--color-X-tint); color: var(--color-X)` (chips) | `bg-X-tint text-X` |
| `accent-color: var(--color-accent)` | `accent-accent` |
| `border-radius:0` on an svg `.chip-dot` | `rounded-none` |
| banner triple `background:X-tint; border-color:X; color:X` | `notice` partial with `tone: :X` |
| `--entity-cols…; min-width…` (dynamic, no token) | **leave** |

---

### Task 1: Foundation — regression guard, banner partial, button sizes

**Command:** `/impeccable polish app/assets/tailwind/application.css` (component extraction: missing token vs one-off, per polish.md §1)

**Files:**
- Create: `spec/views/no_inline_token_styles_spec.rb`
- Create: `app/views/shared/_notice.html.erb`
- Modify: `app/assets/tailwind/application.css` (near `.btn-primary` ~317 and `.notice-banner` ~398)
- Modify: `app/views/layouts/application.html.erb:60-65` (use the partial)

**Interfaces:**
- Produces: CSS `.btn` (padding `0.5rem 0.875rem`, `font-size: 0.875rem`), `.btn-sm` (padding `0.375rem 0.75rem`, `font-size: 0.875rem`), `.notice-banner--danger|warning|success`.
- Produces: partial `shared/notice`, called as `<%= render layout: "shared/notice", locals: { tone: :danger, role: "alert" } do %>…<% end %>`; `role` optional (omit for a static banner).

- [ ] **Step 1: Write the failing guard spec**

```ruby
# spec/views/no_inline_token_styles_spec.rb
require "rails_helper"

RSpec.describe "view templates" do
  INLINE_TOKEN_STYLE = /style(?:=|:\s*)["'][^"']*var\(--color-/

  it "never restate a design token in an inline style" do
    offenders = Dir[Rails.root.join("app/views/**/*.erb")].sort.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        "#{Pathname(path).relative_path_from(Rails.root)}:#{i + 1}" if line.match?(INLINE_TOKEN_STYLE)
      end
    end

    expect(offenders).to be_empty,
      "Use the token utilities (text-ink-soft, bg-danger-tint, …) or a component class:\n#{offenders.first(20).join("\n")}"
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bundle exec rspec spec/views/no_inline_token_styles_spec.rb`
Expected: FAIL listing ~150 offenders. (Tasks 2–5 drive this to zero.)

- [ ] **Step 3: Add the CSS components** (after `.btn-text:hover`, and after `.notice-banner`)

```css
.btn, .btn-sm {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 0.875rem;
  line-height: 1.25rem;
}
.btn { padding: 0.5rem 0.875rem; }
.btn-sm { padding: 0.375rem 0.75rem; }

button:not(:disabled) { cursor: pointer; }

.notice-banner--danger  { background: var(--color-danger-tint);  border-color: var(--color-danger);  color: var(--color-danger); }
.notice-banner--warning { background: var(--color-warning-tint); border-color: var(--color-warning); color: var(--color-warning); }
.notice-banner--success { background: var(--color-success-tint); border-color: var(--color-success); color: var(--color-success); }
```

- [ ] **Step 4: Add the partial**

```erb
<%# shared/_notice.html.erb — one banner. tone: :danger|:warning|:success. role: optional live-region role. %>
<%= tag.div class: ["notice-banner", "notice-banner--#{tone}", local_assigns[:class]], role: local_assigns[:role] do %>
  <%= yield %>
<% end %>
```

- [ ] **Step 5: Use it in the layout** — replace the two `<p … style=…>` flashes:

```erb
<% if notice %>
  <%= render layout: "shared/notice", locals: { tone: :success, role: "status", class: "mb-6" } do %><%= notice %><% end %>
<% end %>
<% if alert %>
  <%= render layout: "shared/notice", locals: { tone: :danger, role: "alert", class: "mb-6" } do %><%= alert %><% end %>
<% end %>
```

- [ ] **Step 6: Rebuild CSS and confirm the existing suites still pass**

Run: `bin/rails tailwindcss:build` then `bundle exec rspec spec/requests/accessibility_spec.rb spec/requests/change_plans_spec.rb`
Expected: PASS (the banner specs assert `role="alert"` / `role="status"`, which the partial still emits). The guard spec still fails.

- [ ] **Step 7: Commit**

```bash
git add spec/views/no_inline_token_styles_spec.rb app/views/shared/_notice.html.erb app/assets/tailwind/application.css app/views/layouts/application.html.erb
git commit -m "refactor(ui): add notice partial, .btn sizes and inline-style guard spec"
```

---

### Task 2: Connections, sessions, health, layout

**Command:** `/impeccable polish app/views/connections app/views/sessions app/views/health app/views/layouts`

**Files:** Modify `connections/{index,show,new,edit,_form}.html.erb`, `sessions/new.html.erb`, `health/show.html.erb`, `layouts/application.html.erb` (remaining inline styles: nav `color:var(--color-ink-soft)`, shared-credential span). Test: `spec/requests/connections_spec.rb`.

**Interfaces:** Consumes Task 1 `.btn`, `.btn-sm`, notice partial, conversion table.

- [ ] **Step 1: Write the failing one-primary spec**

```ruby
# in spec/requests/connections_spec.rb (create the file if absent; reuse the suite's existing login/connection setup)
RSpec.describe "GET /connections", type: :request do
  it "fills only one action (Add connection); per-row Log in is secondary" do
    create_list(:kong_connection, 2)
    get connections_path
    doc = Nokogiri::HTML(response.body)
    expect(doc.css(".btn-primary").map { |n| n.text.strip }).to eq(["Add connection"])
    expect(doc.css("a.btn-secondary").map { |n| n.text.strip }.count("Log in")).to eq(2)
  end
end
```

Run: `bundle exec rspec spec/requests/connections_spec.rb` → FAIL (3 `.btn-primary`). If the factory name differs, use the one in `spec/factories`.

- [ ] **Step 2:** In `connections/index.html.erb` change the per-row "Log in" to `btn-secondary btn-sm` and "Edit" to `btn-text btn-sm`; "Remove" stays `btn-text-danger btn-sm`. Header "Add connection" → `btn-primary btn`. Keep `connections/show.html.erb` "Log in" as the single `btn-primary btn` (one connection, one primary).
- [ ] **Step 3:** Replace every `px-… py-… text-sm` button sizing on these views with `.btn`/`.btn-sm`; drop `cursor-pointer` (now global).
- [ ] **Step 4:** Apply the conversion table to every inline style in these files, including the layout's nav (`text-ink-soft` on the `<nav>`) and the shared-credential span. Replace hand-written banners with the notice partial.
- [ ] **Step 5:** Run `bundle exec rspec spec/requests/connections_spec.rb spec/requests/sessions_spec.rb spec/requests/accessibility_spec.rb` → PASS.
- [ ] **Step 6: Commit** the files listed above plus the spec, by path.

---

### Task 3: Entities, plugins, certificates

**Command:** `/impeccable polish app/views/entities app/views/plugins app/views/certificates`

**Files:** Modify `entities/{index,index.turbo_stream,new,edit,show,_entity,_entity_row,_certificate_details,_count,_pagination}.html.erb`, `plugins/{new,_schema_reference}.html.erb`, `certificates/expiring.html.erb`. Test: `spec/requests/entities_spec.rb`, `spec/requests/accessibility_spec.rb`.

- [ ] **Step 1: Write the failing spec** in `spec/requests/entities_spec.rb`: on `GET /entities?type=upstream`, `.btn-primary` texts are exactly `["New upstream"]` and the Filter control has `btn-secondary`; on `type=service` there is no `.btn-primary` beyond what the header already renders (assert `count <= 1`). Run → FAIL (Filter is primary).
- [ ] **Step 2:** `entities/index.html.erb:50` Filter → `btn-secondary btn`. Header "New …" links → `btn-primary btn`. Edit/new forms keep their single "Review change" as `btn-primary btn`.
- [ ] **Step 3:** Apply the conversion table to every file above. `_entity_row.html.erb` alone holds 13 sites; keep the two `—` placeholders as `text-ink-faint` and leave the Ruby comments untouched. `--entity-cols` dynamic style in `index.html.erb` stays.
- [ ] **Step 4:** Replace each hand-written banner with the notice partial (rich content such as a dependents list goes in the block).
- [ ] **Step 5:** `bundle exec rspec spec/requests/entities_spec.rb spec/requests/plugins_spec.rb spec/requests/certificates_spec.rb spec/requests/accessibility_spec.rb` → PASS.
- [ ] **Step 6: Commit** by path.

---

### Task 4: Change plans, audit events

**Command:** `/impeccable polish app/views/change_plans app/views/audit_events`

**Files:** Modify `change_plans/{index,show}.html.erb`, `audit_events/index.html.erb`. Test: `spec/requests/change_plans_spec.rb`.

- [ ] **Step 1:** `show.html.erb` has 25 inline styles and the largest banner cluster (applied / pushed / failed / expired). Convert styles per the table; convert each banner to the notice partial. **Preserve** `role="alert"`/`role="status"` semantics (existing spec asserts them) and the `.failure-reason` block inside the banner.
- [ ] **Step 2:** `index` and `audit_events/index`: convert `border-bottom`/`bg-surface-subtle` header-row styles and `text-ink-soft` cells.
- [ ] **Step 3:** `bundle exec rspec spec/requests/change_plans_spec.rb spec/requests/audit_events_spec.rb` → PASS. Do not edit expected strings in existing specs; a failure means a regression in the refactor.
- [ ] **Step 4: Commit** by path.

---

### Task 5: Tokens, remaining semantics, product name

**Command:** `/impeccable harden app/views` (semantics/a11y sweep, scoped to what the critique still has open)

**Files:** Modify `personal_access_tokens/{index,new}.html.erb`, every `<th>` in `app/views/**` (22 without `scope`), `layouts/application.html.erb:4,7`. Test: `spec/requests/accessibility_spec.rb`.

- [ ] **Step 1: Write the failing spec**

```ruby
describe "tables" do
  it "scopes every column header on the list pages" do
    [audit_events_path, change_plans_path, expiring_certificates_path].each do |path|
      get path
      Nokogiri::HTML(response.body).css("thead th").each do |th|
        expect(th["scope"]).to eq("col"), "#{path}: <th> #{th.text.strip.inspect} lacks scope=col"
      end
    end
  end
end
```

Run → FAIL. Adjust the path helpers to the real route names.

- [ ] **Step 2:** Add `scope="col"` to each `<th>` in a `<thead>`; row headers use `scope="row"` (the plan diff table already does).
- [ ] **Step 3:** Convert the remaining inline styles in the tokens views per the table; tokens "new" secret display keeps its existing copy-once messaging.
- [ ] **Step 4:** Product name: layout `<title>` fallback `"Kong CE Control Plane"` → `"Kongsole"`, `application-name` `"Kong Integration"` → `"Kongsole"` (wordmark is already "Kongsole"). No other copy edits.
- [ ] **Step 5:** `bundle exec rspec spec/views spec/requests` → PASS, including the Task 1 guard now at zero offenders.
- [ ] **Step 6: Commit** by path.

---

### Task 6: Document

**Command:** `/impeccable document` (update `docs/UI-DESIGN.md` only; do not generate a root DESIGN.md)

**Files:** Modify `docs/UI-DESIGN.md`.

- [ ] **Step 1:** In Components add `.btn` / `.btn-sm` (size modifiers; the color class supplies the role), `.notice-banner--danger|warning|success` and the `shared/_notice` partial, and the rule "colors reach markup through token utilities (`text-ink-soft`, `bg-danger-tint`), never inline `style`" (enforced by `spec/views/no_inline_token_styles_spec.rb`).
- [ ] **Step 2:** Update "Views covered" to include entities (index/new/edit/show), plugins/new, certificates/expiring, audit_events, change_plans/index, personal_access_tokens.
- [ ] **Step 3:** Restate the one-filled-action-per-view rule with the per-row Log in / Filter examples.
- [ ] **Step 4: Commit** `docs/UI-DESIGN.md`.

---

### Task 7: Verify (bounded: one batched round, one fix batch, at most one confirm)

**Command:** `/impeccable polish app/views` §5 verification; agent `impeccable-finish-reviewer` for the review.

- [ ] **Step 1:** `bundle exec rspec` (full suite) → all green. Report the exact counts.
- [ ] **Step 2:** Start the app (`bin/dev` or `bin/rails s` after `bin/rails tailwindcss:build`) and capture desktop (1280) and mobile (390) screenshots in one batch: connections index, login, entities (a list with rows, service, and upstream), entity edit, certificates expiring, audit, change plans index and a plan show (pending at dev, pending at prod), tokens. Needs a reachable Kong or seeded cache; if none exists, say which screens could not be rendered.
- [ ] **Step 3:** Dispatch `impeccable-finish-reviewer` on the diff with `docs/UI-DESIGN.md` as the bar; fix every material finding in one batch.
- [ ] **Step 4:** One confirm round for touched screens only, then stop. Close the critique snapshot:
  `.claude/skills/impeccable/scripts/impeccable critique-storage close "app/views" "2026-09-21T10-42-02Z__app-views.md"` only if every P1/P2 it lists is cleared; otherwise leave it open and list what remains.

## Self-review

- **Spec coverage:** inline styles (T1 guard, T2–5), banners (T1, T2–4), one-primary rule (T2, T3), button sizing (T1–3), semantics (T5), doc update (T6), verification with app started by me (T7). The critique's contrast items are already covered by `spec/assets/design_tokens_contrast_spec.rb`; `lang`, `aria-current`, labels and live regions already exist and are tested, so they are not repeated here.
- **Placeholders:** none. Route/factory/helper names are flagged "adjust to the real name" only where I have not read the file; the implementer reads `spec/factories` and `config/routes.rb` first.
- **Consistency:** `.btn`/`.btn-sm`/`shared/notice`/`tone:` are defined in Task 1 and used identically in Tasks 2–5.
- **Parallelism:** Tasks 2, 3, 4 touch disjoint files and can run as parallel subagents after Task 1. Task 5 runs after them because it edits the same files (`<th>` scope, tokens views). Rails specs share the test DB, so parallel agents should run only their own spec files.
