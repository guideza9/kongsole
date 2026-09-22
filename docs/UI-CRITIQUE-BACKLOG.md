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
- [x] **3. `harden`: keyboard and assistive-tech gaps (P3).**
  - **Skip link.** `layouts/application.html.erb` now opens with a "Skip to
    content" link to `#main`; `<main>` carries `id="main" tabindex="-1"`. The
    `.skip-link` rule (`application.css`, just under `:focus-visible`) parks it
    off-screen until focused rather than hiding it, and `main[tabindex="-1"]`
    takes no focus ring of its own.
  - **Tab focus clipping.** `.tab:focus-visible { outline-offset: -2px }` draws
    the ring inside the tab, where the `.tab-nav` scroll container cannot shave
    it. (`overflow-x: auto` clips on both axes, so the old 2px-outside ring was
    cut off the end tabs and off every tab's top edge.)
  - **JSON editor in forced-colors.** A new `@media (forced-colors: active)`
    block beside `.json-editor` hides the highlight overlay and gives the
    textarea `Field`/`FieldText`, so the forced opaque text is not doubled over
    the highlighted copy. The invalid state switches from a danger border to a
    2px dashed one, which is shape rather than fill.
  - **Re-auth password.** `required` added to the field in the plan review
    action bar (`change_plans/show.html.erb`).
  - **Flash banners.** They kept `role="status"`/`role="alert"`, but a flash is
    parsed together with its region, so there is no change for the region to
    report. `flash_controller.js` lifts the text out on connect and puts it back
    in the next frame — before paint, so nothing flickers — and with JS off the
    server-rendered banner stands untouched.
  - **JSON editor errors.** `json_editor_controller.js` no longer surfaces
    `error.message`. `plainError`/`errorSpot` rewrite the failure in the app's
    words and name the line and column, reading Firefox's `line N column M` or
    V8/Safari's character offset. Verified against eight malformed documents in
    Node and again in a live Edge session; the Firefox and Safari phrasings are
    matched by regex and were not executed.

## Still to do, in this order

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
- Step 3 was verified against the running app (`bin/rails server` on :3000, the
  compose Kong stack, logged in as `jakkapat`/`ro-kongctl` from
  `docker/kong/bootstrap.sh`) and in a real browser, driven through
  playwright-core against the installed Edge. What was confirmed:
  - **Skip link** is the first thing Tab reaches, at 0,0, hit-testing above the
    topbar, white on ink with the inset ring; Enter moves focus to
    `main#main`, which shows no ring. Holds at 390px and 1280px, and the
    off-screen park adds no horizontal page overflow.
  - **Tab focus ring** is no longer clipped: on the first and last tab the
    ring's outer edge lands exactly on the `.tab-nav` edge, and a screenshot of
    the focused first tab shows all four sides. (The earlier "clipped" reading
    was a bad probe — for a negative `outline-offset` the outer edge is
    `left - offset - width`, not `left + offset - width`.)
  - **JSON editor in forced-colors** (`forcedColors: "active"`): the overlay is
    `display: none` with zero client rects and the textarea is opaque
    `FieldText` on `Field`. Re-enabling just that one declaration brings the
    defect back (overlay painting *and* opaque textarea = two stacked copies),
    so the fix is load-bearing. Note: Chromium's screenshot path does not honour
    forced-colors emulation — captures come back in authored colour even with
    zero client rects — so the CSSOM is the evidence here, not the PNGs.
  - **Re-auth password**: `required` is present on a live rank-2 plan review
    page (uat, PR mode).
  - **Flash banners**: a `MutationObserver` installed before page scripts sees,
    after the login redirect, a removal then an addition of the message inside
    an already-connected `role="status"` — the childList change AT live-region
    processing keys on. Without the controller there is no mutation at all.
    Not spoken-tested: no NVDA/JAWS here, so this proves the mechanism fires,
    not that a specific screen reader voices it.
  - **JSON editor errors**: five malformed documents typed into the live
    editor return the plain-language copy with the right line and column, and
    submit stays disabled; valid input returns "Valid JSON · 2 fields".
- The `required` on the re-auth password has no spec, but it was confirmed on
  the live page instead. `confirm_env_name` deliberately keeps no `required`:
  an exact-match requirement is not something the attribute can express, and
  the env-confirm controller plus the server already gate it.
- Specs: the test config in `config/database.yml` has no credentials, and this
  environment lacks the Active Record encryption credential. Running with
  `DATABASE_URL=postgres://kongsole:kongsole@localhost:5433/kong_integration_test`
  gave 843 examples with 49 failures (841 before step 3's two new examples),
  all "Missing Active Record encryption credential" (`api/v1/change_plans_spec`, `api/v1/certificates_spec`, plus one
  each in `kong_connection_spec` and `connection_login_spec`). No other spec
  fails. Set up the encryption credentials to get a clean run; `config/master.key`
  is absent, so `config/credentials.yml.enc` cannot be opened to add them here.
- Nokogiri's `at_css(selector, text: "...")` does not filter by text (the hash
  is read as namespaces). Filter with `.css(...).map(&:text)` instead.
- All of this work is uncommitted on branch `feature/update_ui_format`.
