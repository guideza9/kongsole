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
  `/health` dashboard. No UI polish pass yet — that's for a later
  `/impeccable` milestone once M1 has real entities to show.
- `docker-compose.yml` + `docker/kong/bootstrap.sh`: a real two-node Kong CE
  stack that fronts its own Admin API via the loopback pattern (section 1),
  used to prove the whole design against a live Kong rather than only mocks.

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
