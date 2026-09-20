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
- PR mode (decK YAML) for these types is M5c: a PR-mode plan for an upstream or target
  raises `NotImplementedError` and stays pending. Certificates, SNIs and the
  private-key-on-env handling are M5b.

## Certificates, SNIs and CA certificates (M5b)

`certificate`, `sni` and `ca_certificate` are managed like every other type, in direct mode
(`docs/DESIGN.md` section 8; design and Kong 3.7 findings in
`docs/superpowers/specs/2026-09-21-m5b-certificates-snis-design.md`).

- **A private key is never accepted.** A certificate's `key` is a reference:
  `{vault://env/cert-payments-key}` makes Kong read `CERT_PAYMENTS_KEY` from its own
  environment, so the key is in neither git nor Kong's database. A pasted PEM is rejected
  with an error (never silently dropped); the API answers 422. In PR mode a decK
  placeholder `${{ env "DECK_CERT_PAYMENTS_KEY" }}` is also accepted (rendering is M5c).
- **Kong does not validate a vault reference**, and a missing variable makes TLS for that
  hostname fail. So applying a certificate whose key reference is new or changed requires
  confirming the variable exists on every Kong node (a checkbox on the review page,
  `acknowledge_env_vars` for `kong_apply`); the confirmation is recorded in the audit event.
- The read-model caches certificate **metadata** (subject, issuer, expiry, fingerprint,
  SANs), not the PEM. **Certificates → Expiring soon** lists what expires within 7/30/90
  days on the current connection; the MCP tool `kong_certs_expiring` covers every connection
  the token can reach.
- Run `bin/rails db:migrate` — M5b adds `audit_events.context`.

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
