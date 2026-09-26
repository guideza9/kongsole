# R5 — Project understanding: design

**Status:** owner review pending · **Date:** 2026-09-27
**Requirement:** `docs/requirements/R5-project-understanding.md` (+ `design-amendments.md` §C6)
**Current plan (to be revised from this spec):** `docs/plans/R5-project-understanding.md`
**Approved UI prototype:** Claude Design canvas https://claude.ai/artifact/PStVYPrCgaS7hYWwF8GfrV
— boards *Overview (desktop)*, *Overview — phone*, *Tracer B (chosen)*, *Tracer B step 4 — service only*.
Tracer A and C stay on the canvas for reference only; nothing is built from them.

## 1. Intent

Someone who takes over a project they have never run, or has to fix one in a hurry, opens one page and learns
what the project is made of, how a request flows through its Kong, and what to know before changing anything.

Success is the owner's 5-minute script (R5.8): a person new to the project answers, using only Kongsole,
*which route `GET api.example.com/echo/x` hits, which service (host:port) it goes to, which plugins run in what
order, what the service receives, and who owns it.*

The owner will use the built pages and comment afterwards; this spec fixes the design to build first.

## 2. Decisions (owner, 2026-09-26/27)

| # | Decision | Replaces in the current plan |
|---|---|---|
| D1 | The overview **extends the existing project page** `/projects/:key` (R1.20). No new overview route. | R5.5 "add `show`" and a separate `projects/show.html.erb` |
| D2 | The tracer answers for **one env at a time**. | — (same) |
| D3 | Team notes show on the **overview only**. | — (same) |
| D4 | Tracer layout **B — the request's journey**: four numbered stops, request → route → plugins → service. Plugins come before the service because Kong runs them before it forwards. | plan listed route, service, plugins |
| D5 | Every stop explains **only its own settings**: stop 2 what the route does to the request (strip, query, Host header); stop 3 the plugins, and a note naming enabled plugins that may stop or change the request; stop 4 only what the service does (where it sends, what it adds, upstream targets, timeouts). | new |
| D6 | Stop 4 shows the **forwarded request** — the exact URL the service receives — built from route and service settings. Plugins are never simulated; they are named. | new |
| D7 | The approximation line names Kong's router as **`traditional_compatible`** (Kong 3.7's default; compose sets no `router_flavor`). | plan said "traditional" |

## 3. Constraints (unchanged from the plan, restated because every unit depends on them)

- Everything from Kong comes from the read-model. No R5 controller, query or service calls Kong; request
  specs run with WebMock and stub nothing.
- Overview and tracer need no login. They read this machine's DB, so they work off the project's network.
- Connection status is the last login's result with its time; `unreachable` shows the project's `network_note`.
- Notes: markdown, no raw HTML, links only http(s)/mailto, files only under `config/projects/`, key checked
  against `Project::KEY_FORMAT`.
- Admin-path entities keep their mark (`.entity-row--admin` / "admin path" tag) wherever they appear.
- Plugin configs are never shown in the tracer, with one exception: `request-termination`'s `status_code`
  and `message` (stop 4, when it answers instead). Plugin data is already redacted in the read-model.

## 4. Units

Each unit is a plain Ruby object with one job, tested alone. None of them touches HTTP.

### 4.1 `ProjectOverview` (query) — `app/queries/project_overview.rb`

`ProjectOverview.new(project).rows -> [Row]`,
`Row = Struct(:env, :connection, :status, :last_connected_at, :synced_at, :counts)`.

- One row per env in `position` order, `connection` nil when the env has none.
- `synced_at` is `connection.last_synced_at`; nil means **never synced on this machine** — the view says so
  instead of showing zeros.
- `counts`: `{"service","route","plugin","consumer","upstream","certificate" => Integer}` from **one** grouped
  query over non-deleted `kong_entities` for the project's connections (no N+1).

### 4.2 `Kong::RouteMatcher` — `app/services/kong/route_matcher.rb`

`Kong::RouteMatcher.call(connection:, host:, path:, method:) -> Result`
`Result = Struct(:route, :service, :matched_on, :losers, :skipped)`; `route` nil means no match.

- Candidates: non-deleted routes of the connection whose `protocols` include `http` or `https`. Routes with an
  `expression` field (expressions router) are skipped and listed in `skipped` with the reason.
- A route matches when all conditions it sets hold (a condition it leaves empty matches anything):
  - **host** — case-insensitive exact, or a wildcard at either end (`*.example.com`, `example.*`); the
    request host is lower-cased and its port dropped before comparing.
  - **method** — in the route's `methods`.
  - **path** — a plain path is a **string prefix** of the request path (so `/billing` also matches
    `/billingx`, as in Kong); a `~` path is a regex anchored at the start, compiled with
    `Regexp.new(..., timeout: 0.1)`. `RegexpError` / `Regexp::TimeoutError` → the route goes to `skipped`
    ("uses regex syntax Kongsole can't read"), never a 500.
- Order among matching routes (the plan's hypothesis, **pinned by the compose check in §6 before coding**):
  more conditions set first → plain host before wildcard host → regex paths by `regex_priority` (high first)
  → prefix paths longest first → oldest `kong_created_at` first.
- `matched_on` records which host, method and path matched, and the matched path string (the prefix, or the
  regex's full match) for §4.4.
- `losers`: the other matching routes, each with the first ordering rule it lost on
  ("a shorter prefix than `/billing/v1`").
- `service`: the route's service from the read-model, or nil (a route without a service — stop 4 says so).

### 4.3 `Kong::PluginChain` — `app/services/kong/plugin_chain.rb`

`Kong::PluginChain.for(connection:, route:, service:) -> [general_steps, consumer_steps]`
`Step = Struct(:plugin, :scope, :priority, :enabled, :overrides, :effect)`.

- Candidate plugins: global, on the service, on the route, on the route+service.
- Same plugin name in several scopes → only the most specific runs: route+service > route > service > global.
  The winner's `overrides` lists the scopes it replaces ("replaces the global one").
- Any instance that names a consumer goes to `consumer_steps`, shown in the "Runs only for certain consumers"
  fold-out, never in the main list or the stop-3 note.
- `priority` from `connection.plugins_available["available_on_server"][name]["priority"]`; general steps sort by
  priority, highest first. A plugin not loaded on the node has no priority: it sorts last and says
  "priority unknown — not loaded on this node".
- Disabled instances stay in the list, struck through and unnumbered, and take no part in the note.
- `effect` from §4.5.

### 4.4 `Kong::ForwardedRequest` — `app/services/kong/forwarded_request.rb` (new)

`Kong::ForwardedRequest.call(match:, request:, steps:, connection:) -> Result`
`Result = Struct(:route_effect, :service_effect, :answered_by)`.

**`route_effect`** (drawn in stop 2):

- `removed` / `kept`: with `strip_path` on, the matched part (§4.2 `matched_on`) is removed; off, nothing is.
- `query`: passed on as sent.
- `host_header`: the client's host when `preserve_host` is on, else the service's host.
- `path_handling`: carried to the join below; stop 2 names it only when it is `v1`.

**`service_effect`** (drawn in stop 4):

- `url`: `protocol://host[:port]` + join(service `path`, kept path) + query, where join follows Kong's documented
  `path_handling` table: **v0** puts a `/` between the two parts when neither side has one, **v1** joins them as
  they are; nothing kept → the service path, or `/`. The whole table is pinned by the compose check (§6).
- `sends_to`: host, port, protocol; `tls_verify` when the protocol is https.
- `upstream`: when the service's host is the name of an upstream in the read-model — its algorithm and its
  targets (`weight > 0`). No such target → `not_forwarded: 503` ("no targets with a weight above 0").
  Target health is not in the read-model and is said to be unknown.
- `timeouts` (connect/read/write) and `retries` from the service.

**`answered_by`**: an enabled, non-consumer `request-termination` in the general steps → stop 4 reads
"Not forwarded — Kong answers the client itself" with its `status_code` and `message`.

### 4.5 `Kong::PluginEffects` — `app/services/kong/plugin_effects.rb` (new)

A fixed table from bundled plugin name to one effect, used by stop 3's note:

| Effect | Plugins (status) |
|---|---|
| may stop | key-auth, basic-auth, jwt, hmac-auth, ldap-auth, oauth2 (401) · acl, ip-restriction, bot-detection (403) · rate-limiting (429) · request-size-limiting (413) |
| may change | request-transformer, pre-function, post-function |
| may answer | proxy-cache (from cache) |
| answers | request-termination (its own status) — handled by §4.4, not the note |

- A **custom** plugin (not in `config/kong_bundled_plugins.yml`) is always named: "Kongsole doesn't know what it
  does."
- Bundled plugins not in the table carry no effect and are not named.
- The note lists only enabled general steps; it ends "Kongsole names these plugins; it does not run them."

### 4.6 `ProjectNotes` — `app/services/project_notes.rb`

As in the plan: `ProjectNotes.new(project, dir:).html -> SafeBuffer | nil`, `#relative_path`; `commonmarker ~> 2.0`
with `unsafe: false`, then any `href` that is not http/https/mailto is removed. Rake `kong:project_notes[key]`
writes the four-heading skeleton (Business flow / Owners / Who to contact / Before you change anything) and never
overwrites. `bundler-audit` clean after the gem is added.

### 4.7 Controllers and routes

- `ProjectsController#show` (exists, no login) gains `@overview`, `@notes_html`, `@notes_path`.
- New `get "projects/:key/trace" => "project_traces#show", as: :project_trace`, no login.
  Params: `env` (an env of the project that has a connection), `method` (from `RouteForm::METHODS`),
  `host` (1–253 chars), `path` (starts with `/`, ≤ 2048 chars, may carry a query). Field errors → 422 with
  `@trace_errors`; an unknown project → 404. No params → the empty form.
- Envs never synced on this machine are listed but not selectable, with the reason.

## 5. UI

Built from the canvas boards named at the top, in the app's existing tokens and marks (UI-DESIGN.md), by the
UI tasks through `/impeccable` (code-led; the canvas is the reference the finish review checks against).

- **Overview:** each env row keeps R1.20's content and adds a counts strip (six counts in fixed columns so envs
  compare at a glance), "Synced …" or "Never synced on this machine…", and a Trace link when synced. Header
  button "Trace a request". A "Team notes" section renders the markdown, or the empty state with the three steps
  (rake → edit file → pull request). Phone: counts wrap to 3 columns; 44 px targets.
- **Tracer (B):** form as one request line (env · method · host · path · Trace) + the approximation line with the
  sync time; then the four stops on a rail; then the fold-outs "Also matched, but lost" and "Runs only for
  certain consumers", plus "Not checked" for skipped routes. No match → "Kong would answer 404 — no route
  matched" and the fold-outs still show near misses if any.
- Colour never carries meaning alone: removed / kept / added path parts are struck / highlighted / boxed and
  labelled in text.

States the UI tasks must cover: never synced; unreachable (with network note); sync older than 24 h (age shown);
no notes; notes with long Thai text; 6+ envs; no route matched; route without service; regex skipped; upstream
with no targets; request-termination answering; a custom plugin in the chain; 390 px.

## 6. Verification against compose Kong (before the matcher and path join are coded)

A throwaway check on the local compose (rank 0 rule): a service pointing back at Kong's own proxy
(`http://127.0.0.1:8000/sink`) and a `sink` route carrying `request-termination` with `echo: true`, so the echoed
request is exactly what a real service would receive. Scratch routes cover: strip on/off, regex, nothing left,
v0/v1 with and without trailing slashes on both sides, preserve_host on/off, and two competing routes per ordering
rule. The recorded results become the fixtures of the matcher and path-join specs, and the scratch entities are
deleted afterwards. If the loop-back does not work, stop and ask before adding an echo container to compose.

## 7. Testing

- Unit specs per unit (§4.1–4.6), including the plan's Review Focus: uncompilable regex → skipped; `/api` vs
  `/api/v1` → longer wins; same plugin global + route → route only, naming what it replaces; never synced →
  "Never synced", not 0; `<script>` / `javascript:` in notes → not rendered.
- Path-join spec: every row of the compose-recorded table plus the canvas's service cases (path / no path /
  https port / upstream / no targets).
- Request specs for overview and tracer: no login, `a_request(:any, //)` never made, 422 per bad field, 404 for an
  unknown key.
- UI snapshots at 390 and 1280 + `impeccable detect`; `hints:todo` reported.
- R5.8: compose walk-through and the owner's 5-minute script.

## 8. Out of scope

Architecture outside Kong; headers/SNI/expressions routing; running or simulating plugins; target health;
editing anything from the tracer (edits stay on the entity pages, behind login).
