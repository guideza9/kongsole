# Kongsole

M0 of `docs/DESIGN.md` (rev 4): foundation, connection registry, and the
admin-path guard. See `PRODUCT.md` for product context and `docs/DESIGN.md`
for the full solution design and milestone plan.

## What's here (M0)

- Rails 8.1 app: Postgres, Solid Queue/Cache/Cable, Tailwind, RSpec.
- `KongConnection` — the connection registry (`app/models/kong_connection.rb`),
  with `ActiveRecord::Encryption` on `auth_secret`, and validation that
  rejects `http://` for anything but localhost (design doc section 3) unless
  `allow_insecure_http` is set — and that flag is reachable **only** from
  `config/connections.yml`, never from the web form.
- `Kong::Client` (`app/services/kong/client.rb`) — maps all six cases from
  design doc section 1.4 (basic-auth rejection, ACL rejection, router
  rejection, entity-not-found, rate limit, upstream down) to distinct
  exception classes.
- `Kong::AccessProbe` — read-write vs read-only detection via a harmless
  probe request (section 3).
- `Kong::CredentialClassifier` — personal vs shared credential detection from
  the Kong consumer's own tags, falling back to `connections.yml`
  (section 2).
- `Kong::AdminPathGuard` — discovers the service/routes/plugins/consumers
  that form a connection's own entry path into its Admin API and fingerprints
  them, so they can never be deleted or rendered into decK YAML later
  (section 1.1 — "the biggest thing this revision has to get right").
- `Kong::Redactor` — strips certificate keys and basic-auth/key-auth secrets
  before anything is persisted (section 8).
- `Kong::ConnectionLogin` / `Kong::ConnectionsConfigLoader` — the login
  pipeline and the git-tracked connection registry loader (section 3).
- Web UI: connection list/add/edit/delete, per-connection login, and a
  `/health` dashboard, styled as a quiet minimalist console — see
  `docs/UI-DESIGN.md` for the palette, type, and component language.
  Future milestones' screens (entity browser, decK diffs, drift)
  extend this system rather than introducing a new one.
- `docker-compose.yml` + `docker/kong/bootstrap.sh`: a real two-node Kong CE
  stack that fronts its own Admin API via the loopback pattern (section 1),
  used to prove the whole design against a live Kong rather than only mocks.

## Upstreams and targets (M5a)

`upstream` and `target` are managed like the other entity types (`docs/DESIGN.md`
section 15, M5), in **direct mode**:

- Browse them under **Upstreams**; an upstream's page has a **Targets** tab, with
  **New upstream** / **Add target** forms that edit Kong's own JSON document and
  land on the normal plan → review → apply → audit pipeline.
- An upstream's `healthchecks` block is edited as JSON, not through a bespoke form.
  Kong validates every upstream/target body at plan time (`POST /schemas/:name/validate`)
  and its per-field errors are shown as-is. **Start from** offers an active HTTP
  health-check preset.
- Kong 3.7 has no global `GET /targets`, so every target path goes through its upstream
  (`Kong::EntityTypes#collection_path` / `#member_path`) and a target plan carries its
  upstream as `parent_kong_id`. The MCP `kong_plan` tool accepts `parent_kong_id` too.
- A target has no `name`; it is identified by its `host:port` everywhere a name would
  show (audit trail, typed-delete confirmation, plan title).
- PR mode (decK YAML) for these types is M5c (see below). Certificates, SNIs and the
  private-key-on-env handling are M5b.

## Certificates, SNIs and CA certificates (M5b)

`certificate`, `sni` and `ca_certificate` are managed like every other type, in direct mode
(`docs/DESIGN.md` section 8; design and Kong 3.7 findings in
`docs/superpowers/specs/2026-09-21-m5b-certificates-snis-design.md`).

- **A private key is never accepted.** A certificate's `key` is a reference:
  `{vault://env/cert-payments-key}` makes Kong read `CERT_PAYMENTS_KEY` from its own
  environment, so the key is in neither git nor Kong's database. A pasted PEM is rejected
  with an error (never silently dropped); the API answers 422. In PR mode a decK
  placeholder is also accepted: enter it as `${{ env "DECK_CERT_PAYMENTS_KEY" }}`, and the tool writes it into the
  config file double-quoted, `"${{ env "DECK_CERT_PAYMENTS_KEY" }}"` (see M5c below).
- **Kong does not validate a vault reference**, and a missing variable makes TLS for that
  hostname fail. So applying a certificate whose key reference is new or changed requires
  confirming the variable exists on every Kong node (a checkbox on the review page,
  `acknowledge_env_vars` for `kong_apply`); the confirmation is recorded in the audit event.
- The read-model caches certificate **metadata** (subject, issuer, expiry, fingerprint,
  SANs), not the PEM. **Certificates → Expiring soon** lists what expires within 7/30/90
  days on the current connection; the MCP tool `kong_certs_expiring` covers every connection
  the token can reach.
- Run `bin/rails db:migrate` — M5b adds `audit_events.context`.

## PR mode and decK (M5c)

In PR mode (`apply_mode: pr`) every managed type except credentials is rendered into the connection's decK YAML
(`docs/DESIGN.md` section 6; design and the decK findings in
`docs/superpowers/specs/2026-09-21-m5c-deck-rendering-design.md`): services, routes, plugins, upstreams, targets,
certificates, SNIs, CA certificates and consumers. Children are nested inside their parent, the way `deck gateway dump`
writes them. **Consumer credentials are never rendered** (decK would sync their password hashes back and break logins);
a PR-mode plan for one is refused with a message saying so.

- **The config file must be in the tool's own format.** The tool checks that re-rendering the file would reproduce it
  byte for byte, and refuses if not — comments, YAML anchors and hand formatting cannot be preserved, and
  `deck gateway sync` deletes whatever is absent from the file. Keys it does not manage (`vaults`, `consumer_groups`,
  flat `routes`) are kept as they are. A file written by an older version of the tool is refused by this input guard
  and must be rewritten in the current format: a bare managed-collection line such as `services:` (what `rake kong:seed` wrote before M5c, which
  decK itself rejects) is tolerated once and dropped on the next render, but a bare `select_tags:` line or the old
  single-quoted key placeholder are not. A file written by an older version can also be refused because an
  empty-hash value (the old writer wrote `key:`, the new one renders `key: null`) or a value the old writer folded across
  lines is not reproduced byte for byte: rewrite it once in the tool's format.
- **A PR-mode connection must have `select_tags`.** Otherwise the apply is refused: decK reads an empty list as the whole
  workspace, so `deck gateway sync` would delete everything absent from the file.
- **decK must be installed** on the machine that applies (tested with 1.51.1 and 1.66.1). Set `DECK_BIN` to use a binary
  that is not on `PATH`. The tool runs `deck file validate` (offline) and `deck gateway diff` (read-only credential).
- **The tool never sees a private key.** A certificate's `key` is a vault reference, or in PR mode a decK placeholder
  written **double-quoted**, `"${{ env "DECK_CERT_X_KEY" }}"`, which **CI** resolves. The CI variable must hold the PEM
  on **one line with literal backslash-n escapes**, not real newlines (measured on Kong 3.7 with decK 1.51.1 and 1.66.1:
  a single-quoted placeholder, or a value with real newlines, fails on sync with `invalid key: pkey.new:load_key`).
  To produce the value from a key file: `awk 'NF {sub(/\r/, ""); printf "%s\\n", $0}' key.pem`. To check the file, the
  tool sets a dummy value for each such variable, so the diff shows the certificate's `key` as changed; that is
  expected. An unset variable in CI fails `deck gateway sync` before anything reaches Kong.
- A certificate created through PR mode gets a UUID from the tool (decK requires an id on certificates); it is recorded
  on the change plan and in the audit event, and is the id Kong ends up with. The id is stored only once the apply
  succeeds.
- A change the tool cannot render faithfully is refused before the repo is touched: a route with no name (decK requires
  one), a child whose parent is not in the file, a certificate update whose entry has no matching id, a duplicate
  certificate id, a rename onto an identity that is already taken, or moving a plugin between scopes (delete it and
  create it again instead).
- **CI gate.** `CiGate` (`bin/deck-ci-gate`) refuses a diff it cannot read, decK-reported `errors`, and a diff with no
  `changes` key (real decK always emits one), in addition to the admin-path and delete-threshold rules.
- **decK and git failures.** A failure of `deck file validate`, `deck gateway diff` or git marks the plan `failed` and
  is shown on the review page; the API answers 422 for decK and 502 for git.

## Setup

```bash
bundle install
bin/rails db:prepare
bin/rails kong:load_connections   # optional: seed the registry from config/connections.yml
bin/dev                           # or bin/rails server
```

Visit `http://localhost:3000`.

## Running against a real (local) Kong

```bash
docker compose up -d
# wait for kong-1-bootstrap to finish (docker compose logs -f kong-1-bootstrap)
echo "127.0.0.1 kong-admin.internal kong-admin-ro.internal" | sudo tee -a /etc/hosts
bin/rails kong:load_connections
```

Then log into the `dev` connection with `jakkapat` / `devpassword` (read-write)
or `ro-kongctl` / `devpassword` (read-only — writes come back as Kong's router
404, reported as "this credential can't write", never a generic error). A
third consumer, `kong-admin`, is tagged `shared-credential` to exercise the
operator-required flow.

Without the `/etc/hosts` step, the stack is still fully verifiable via curl
(see comments at the top of `docker-compose.yml`) and the app's login/guard
logic is fully covered by the RSpec suite against realistic Kong Admin API
responses.

`docker compose down -v` tears the stack (and its Postgres volume) down.

## Tests

```bash
bundle exec rspec       # 60 examples
bundle exec rubocop     # rubocop-rails-omakase
bundle exec brakeman -q
```

## Not in M0

Everything past the foundation: `kong_entities` sync, the entity browser,
decK PR mode, plugins, upstreams/targets/certificates, drift detection, and
the MCP server. See `docs/DESIGN.md` section 15 for the M1–M6 plan.
