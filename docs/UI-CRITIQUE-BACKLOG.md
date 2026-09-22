# UI critique backlog (app/views)

Source: `/impeccable critique` run on 2026-09-22, snapshot in
`.impeccable/critique/2026-09-21T18-00-36Z__app-views.md`. Score 28/40 (Good).
Trend across runs: 24 → 26 → 27 → 28 → 28. Re-run `/impeccable critique` after
finishing this list to see the score move.

Visual language stays as documented in `docs/UI-DESIGN.md` (quiet minimalism,
Operate mode). Nothing below changes it.

## Done in this round

- [x] **1. `clarify`: data freshness (P1).**
  - Entities list says how old the sync is ("Synced from X 5 minutes ago."),
    warning-toned and worded "so it may be out of date" after
    `EntitiesHelper::SYNC_STALE_AFTER` (1 hour), and says "Never synced" when
    nothing has synced. It dates the list by its *oldest* row, so an apply's
    write-through refresh of one row cannot make the rest look fresh.
  - Health: intro says the status is from the last login attempt and is not
    live; column renamed "Last known status". The "Log in" button keeps its
    label (`consistency_spec` requires it to match the connection card).
- [x] **2. `shape` → build: pipeline and human/agent parity (P1).**
  - "via agent" tag (`ChangePlansHelper#actor_summary`) on the plan byline,
    Pending PRs and Audit. Human rows are unmarked.
  - Pending PRs: state in words, "Branch" column links `kongctl/<id>` when the
    connection has a `git_web_url`.
  - Audit rows link to their plan; an applied plan's bottom row offers "View
    audit entry" and "View <entity type>".
## Still to do, in this order

### 3. `harden`: keyboard and assistive-tech gaps (P3)

Chosen scope for this round. Each item was reasoned from source only; nothing
was checked in a browser, so verify each one in a real browser first.

- [ ] **Skip link.** None exists before the sticky, three-row topbar
  (`app/views/layouts/application.html.erb`, topbar around lines 31-60). Add a
  visually hidden "Skip to content" link as the first focusable element, and
  give `<main>` an id.
- [ ] **Tab focus clipping.** `.tab-nav { overflow-x: auto }`
  (`app/assets/tailwind/application.css`, ~136-139) will likely clip the 2px
  focus outline on `.tab` links. Give it padding or an inset outline offset.
- [ ] **JSON editor in forced-colors / Windows High Contrast.** The editor uses
  `color: transparent` over an `aria-hidden` overlay (`application.css` ~771;
  `app/javascript/controllers/json_editor_controller.js`). The existing
  forced-colors blocks (~1153, ~1367) do not cover it, so text may render
  doubled or invisible. Add a fallback.
- [ ] **Re-auth password.** No `required` on the field in the plan review
  action bar (`app/views/change_plans/show.html.erb`, ~349-356).
- [ ] **Flash banners.** Rendered at page load in the layout (~61-66), so they
  are probably not announced after a redirect. Give them a live-region role
  (`role="status"`, or `role="alert"` for errors) and check the announcement.
- [ ] Also from the same review: JSON editor errors show the raw
  `error.message` (`json_editor_controller.js` ~159); make them plain language.

### 4. `polish`: final pass over everything touched

Run after step 3, over the files touched in steps 1-3. Also fold in the minor
observations below if wanted.

## Not chosen this round (P2, revisit later)

- [ ] **Entity detail page has inverted hierarchy**
  (`app/views/entities/show.html.erb`, ~57-97; suggested command: `layout`).
  Edit/Delete sit at the bottom, and a fully expanded raw JSON block pushes the
  child Routes/Plugins lists down. Child rows drop identifying fields
  (`entities/_entity.html.erb`).
  Fix: move Edit/Delete into the header; make Raw JSON a `.disclosure` as on the
  review page; reuse `route_match` and `scope` in child rows; label Delete
  "Propose delete".
- [ ] **List efficiency and dead weight** (`distill`).
  - `.entity-link::after` (`application.css` ~388) covers the whole row, so
    hosts, paths and cert names cannot be selected or copied. Keep the link
    overlay but lift selectable cells above it.
  - The Status column is "—" for nearly every row
    (`entities/_entity_row.html.erb` ~68-70). Fold it into the Name cell chips.
  - The certificates header has about 13 controls
    (`entities/index.html.erb`). The plugin catalog (`plugins/new.html.erb`) is
    an unsearchable name list.
  - Services, routes and consumers have no create path here; state that
    deliberately instead of leaving it silent.

## Minor observations (fold into polish if wanted)

- `diff_chip` and `expiry_badge` use inline `style="…var(--color…)"`
  (`application_helper.rb` ~180, ~227), against the convention in `UI-DESIGN.md`.
- The `@theme` comment says "four sizes" but lists three (`application.css`
  ~26-33).
- The tokens page shows a new token only in a flash, with no copy button
  (`personal_access_tokens/index.html.erb`).
- The connection show page's h1 is `sr-only`, so sighted users see badges only.
- A delete plan stacks two banners (dependent routes, then the delete notice)
  before the summary strip.
- The admin-path row uses the same warning tint as warning status, so it can
  read as "problem" instead of "protected" (`application.css` ~407).
- The login warning fires for prod only (`@connection.prod?`), so uat, also a
  protected rank, is silent (`sessions/new.html.erb`).
- "Pending PRs" stays in the nav on direct-mode connections, where it is always
  empty (`layouts/application.html.erb` ~38).
- Direct apply redirects to the entity page with the plain-text flash "Applied.
  Recorded in the audit log."; the new plan exits only show when the plan is
  reopened. Consider linking the flash.
- `kong_connections.last_synced_at` and `last_sync_status` exist in the schema
  but nothing writes them. Decide whether to record a full-sync timestamp on
  the connection.
- PR number and URL are never recorded (`change_plans.pr_url`, `pr_number` are
  unused; only `commit_sha` and `pr_state = "branch_pushed"` are set). Showing a
  PR link needs a backend change to capture it first.

## Open decisions

- **Stale threshold**: 1 hour is a guess (there is no scheduled sync). Confirm
  the team's real sync cadence.
- **Persistent plan-lifecycle stepper** (plan → guardrail → review → apply →
  audit): deliberately not built. Closure links were chosen instead.
- **Landing on "plans awaiting me"** instead of Connections: raised in the
  critique, not chosen.

## Working notes for whoever resumes

- The `impeccable detect` scan does not read `.erb` files, so it cannot validate
  these views. Rely on review and a real browser; only `application.css`
  scans validly.
- Specs: the test config in `config/database.yml` has no credentials, and this
  environment lacks the Active Record encryption credential. Running with
  `DATABASE_URL=postgres://kongsole:kongsole@localhost:5433/kong_integration_test`
  gave 841 examples with 49 failures, all "Missing Active Record encryption
  credential" (`api/v1/change_plans_spec`, `api/v1/certificates_spec`, plus one
  each in `kong_connection_spec` and `connection_login_spec`). No other spec
  fails. Set up the encryption credentials to get a clean run.
- Nokogiri's `at_css(selector, text: "...")` does not filter by text (the hash
  is read as namespaces). Filter with `.css(...).map(&:text)` instead.
- All of this work is uncommitted on branch `feature/update_ui_format`.
