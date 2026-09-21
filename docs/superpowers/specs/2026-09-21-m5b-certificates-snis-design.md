# M5b — Certificates, SNIs, CA certificates, private key on env

Status: approved, not yet implemented · 2026-09-21
Follows M5a (upstreams + targets). Precedes M5c (decK rendering for every type).

Scope in one line: manage `certificate`, `sni`, and `ca_certificate` through the
existing plan → review → apply → audit pipeline, with a private key that never
enters this tool, git, or Kong's database.

---

## 1. Why this needs a policy layer

Verified against Kong 3.7.1 CE on a throwaway node, with the key present only as
an environment variable on that node (spike run 2026-09-21, torn down after):

| # | Behaviour | Consequence for this design |
|---|---|---|
| 1 | `vaults: ["bundled"]` — the `env` vault backend is available in CE | Path A is viable on CE, as DESIGN §8 assumed |
| 2 | `POST /certificates` with `key={vault://env/cert-spike-key}` → **201**; the key is stored and returned **verbatim as the reference string**, never resolved | The tool can show the reference; it never sees a PEM |
| 3 | `{vault://env/...}` naming a variable that **does not exist** → **201, no error** | Kong will not catch a typo. Nothing else will either |
| 4 | A vault reference whose key **does not match the certificate** → **201** | Kong skips its cert/key match check for references |
| 5 | A **plaintext** mismatched cert/key → **400** `certificate does not match key` | Kong only validates when it can see the key |
| 6 | With the variable correctly set, TLS on the SNI serves the right certificate (confirmed by handshake) | The mechanism works end to end |
| 7 | With the variable missing, the handshake fails: `tlsv1 alert internal error` (alert 80) | A typo is invisible until a client's HTTPS breaks |
| 8 | `{vault://env/cert-payments-key}` reads the variable `CERT_PAYMENTS_KEY` (uppercased, dashes → underscores) | The tool can show operators the exact variable to set |

Rows 3, 4 and 7 are the whole reason for section 3 below. Kong accepts a broken
reference without complaint, and the failure surfaces later as a TLS handshake
error on a hostname in production. **The guard has to live in this tool, because
there is no other layer that will catch it.**

Other confirmed API shapes:

- `/certificates`, `/snis`, `/ca_certificates` are all flat, top-level
  collections with standard `data`/`offset`/`next` pagination. None needs the
  nested-path machinery M5a added for targets.
- A certificate's JSON carries `snis` as an array of hostnames, kept current by
  Kong whether the SNI was created inline (`snis[]=` on the certificate) or
  separately via `POST /snis` with `certificate.id`.
- An SNI's JSON carries `certificate: {id}` — its parent reference.
- A CA certificate has `cert` and `cert_digest` (SHA-256) and **no key field**.
- `/schemas/certificates`, `/schemas/snis` and `/schemas/ca_certificates` all
  answer 200, and `POST /schemas/certificates/validate` accepts a body whose
  `key` is a vault reference. Plan-time validation works exactly as in M5a.

**Not conclusively verified:** whether `PATCH`ing a certificate's `key` to a
plaintext PEM is accepted. The call returned 200 but the value read back
unchanged, which the spike did not resolve. It does not affect this design —
section 3 rejects plaintext before any request reaches Kong — but nothing below
should be read as a claim about it.

---

## 2. Entities, identity, and sync

Three new types in `Kong::EntityTypes`, all flat (`list_path` only, no
`nested_collection_proc`), each with a `schema_name` so plan-time validation
applies:

| type | `list_path` | `schema_name` | parent |
|---|---|---|---|
| `certificate` | `/certificates` | `certificates` | — |
| `sni` | `/snis` | `snis` | `certificate` |
| `ca_certificate` | `/ca_certificates` | `ca_certificates` | — |

Identity follows DESIGN §7's table:

| type | display name | logical_key | parent_kong_id |
|---|---|---|---|
| `certificate` | first SNI, else fingerprint[0..11] | sorted SNI list joined by `,`, else fingerprint | — |
| `sni` | `name` (the hostname) | `name` | `certificate.id` |
| `ca_certificate` | `cert_digest[0..11]` | `cert_digest` | — |

`Kong::EntityTypes.label` gains no new branch: a certificate and a CA
certificate are identified by the computed `name` on the read-model row, and an
SNI has a real `name`. For a **certificate**, however, `before["name"]` does not
exist in Kong's own JSON — the name is derived. So `ChangePlan#entity_label`
falls back to the first SNI, then the fingerprint, for `certificate`, the same
way it already falls back to `target` for a target.

Sync order becomes `... upstream, target, certificate, sni, ca_certificate` — a
certificate before its SNIs, so an SNI's parent name resolves. After a **write**
to an SNI, its parent certificate is re-synced, because adding or removing an
SNI changes the certificate's own derived name and logical key.

### Metadata only, never the PEM

Per DESIGN §8, the read-model caches certificate **metadata**, not the
certificate body. A new `Kong::CertificateMetadata` parses the `cert` PEM with
Ruby's own `OpenSSL::X509::Certificate` and returns:

`subject`, `issuer`, `serial`, `not_before`, `not_after`, `fingerprint_sha256`,
and `sans` (subject alternative names).

`Kong::EntitySync` calls it for a `certificate` or `ca_certificate`, stores the
result under `data["_metadata"]`, and drops the `cert` / `cert_alt` PEM bodies
it parsed from. The public certificate is not secret, but caching a full PEM per
certificate per connection is bulk with no reader — the dashboard, the list
columns and the detail page all read metadata.

This is sync's job, not `Kong::Redactor`'s. The redactor's one responsibility is
removing secrets, and a public certificate is not one; folding "also parse and
summarise this field" into it would blur the boundary that makes it easy to
reason about. The redactor's only change here is the reference passthrough in
section 3.

`not_after` is written to the existing indexed `kong_entities.not_after` column
(already in the schema, already indexed, unused until now).

**A PEM that will not parse must never fail a sync.** `CertificateMetadata`
returns `{parse_error: "..."}` and sync continues; the UI shows the certificate
with its metadata unavailable rather than dropping the row.

---

## 3. Private-key policy

A new `Kong::CertificateKeyPolicy`, applied to `key` and `key_alt` on
`certificate` (no other type has a key field — an SNI has none, and a CA
certificate has none).

Two accepted forms:

| form | accepted where | why |
|---|---|---|
| `{vault://env/name}` | **everywhere** (direct and PR mode) | Kong resolves it at runtime from its own environment. The key is in neither git nor Kong's DB. This is DESIGN §8's "ทาง ก", the recommended path |
| `${{ env "DECK_NAME" }}` | **PR mode only** | decK substitutes it when CI runs the sync. Nothing injects it in direct mode, so a direct-mode connection would write the literal string into Kong. This is "ทาง ข" |

**Everything else is rejected**, including any value containing
`-----BEGIN`. The message names the problem and the fix:

> A private key can't be set from here. Reference one instead:
> `{vault://env/cert-payments-key}` (read from `CERT_PAYMENTS_KEY` on every Kong
> node), or in PR mode `${{ env "DECK_CERT_PAYMENTS_KEY" }}`.

Rejection is a `Kong::ChangePlanner::InvalidChange` subclass, so the web UI
re-renders with the operator's JSON intact and the API answers 422 — the
behaviour M5a established.

**Loud rejection replaces silent dropping.** Today `Redactor.prune_sensitive`
strips a secret-named field from a form submission without saying so, which is
right for a credential nobody should be setting from a form, but wrong here: an
operator who pastes a PEM into a certificate would get a plan that silently
omits the key and a certificate Kong cannot serve. The policy runs **before**
pruning and raises.

Enforced in `Kong::ChangePlanner` so all three surfaces (web, REST, MCP) share
one rule, and re-checked in `Kong::ChangeApplier` as defense in depth, since a
plan can sit pending for 15 minutes and `apply_mode` could change underneath it.

### Redaction

A vault reference is not secret — it is a pointer, and operators need to see
which variable a certificate uses. `Kong::Redactor` gains a narrow exception:
for `certificate`'s `key` and `key_alt` **only**, a value that
`CertificateKeyPolicy.reference?` recognises passes through verbatim. Any other
value in those fields is still `[REDACTED]`, and every other entity's secret
fields are untouched. A `keyauth_credential`'s `key` keeps its current
behaviour.

---

## 4. The guard: validate + acknowledge

Since Kong accepts a broken reference silently (spike rows 3, 4, 7), the tool
makes the operator confirm the variable exists.

1. **Resolve and display.** `CertificateKeyPolicy.env_var_name` turns
   `{vault://env/cert-payments-key}` into `CERT_PAYMENTS_KEY` (verified mapping,
   spike row 8). The new-certificate form, the review page and the certificate
   detail page all show it.
2. **Acknowledge before apply.** A plan whose `after` sets a vault-referenced
   key requires a ticked checkbox — "`CERT_PAYMENTS_KEY` is set on every Kong
   node in this connection" — on the review page. `ChangeApplier` refuses
   without it, the same shape as the existing typed-name delete confirmation.
3. **Agents acknowledge explicitly.** An agent cannot tick a box, so
   `kong_apply` takes `acknowledge_env_vars: true`. Omitted, the apply is
   refused with a message naming the variables. This is deliberately not
   inferable — the point is a human asserting an out-of-band fact.
4. **Record it.** The acknowledgement and the variable names go into the audit
   event, so "who said this variable was set, and when" is answerable later.

Only a plan that **sets or changes** a key reference needs this. Editing a
certificate's tags, or adding an SNI, does not.

### Migration

One migration: `add_context_to_audit_events` — a nullable `jsonb` `context`
column on `audit_events`. It holds `{"acknowledged_env_vars": ["CERT_X_KEY"]}`
here, and is a general slot for future per-event facts that do not deserve their
own column. `AuditEvent` stays append-only and `readonly?` is unchanged.

---

## 5. Expiry

`KongEntity` gains an `expiry_status` **method** (no column, no migration —
`not_after` already exists and is already indexed), derived from `not_after`:

| status | when |
|---|---|
| `expired` | `not_after` is in the past |
| `critical` | within 7 days |
| `warning` | within 30 days |
| `ok` | later than 30 days |
| `nil` | no `not_after` (every non-certificate entity) |

Rendered with the existing `status_badge` tones — danger for expired and
critical, warning for warning — so it reads like every other status in the app.

Two audiences, two scopes:

- **Web dashboard** (`/certificates/expiring`): the **current connection** only.
  A web session holds one connection's credential and the header shows that
  connection's colour badge; a cross-connection table would contradict the
  environment guardrail DESIGN §14 calls "the cheapest, most effective".
- **REST + MCP** (`kong_certs_expiring`): **every connection the token can
  reach**, since an agent asking "what expires soon" means across the estate.
  Takes an optional `connection` filter and a `days` window (default 30).

Both read the read-model only. Neither calls Kong.

---

## 6. Surfaces

**Web**

- Tabs: **Certificates** and **CA certificates**, alongside the existing five.
  SNIs are not a top-level tab — they are a child group on the certificate page,
  the pattern targets established.
- Certificate list columns: name (first SNI), SNI count, expiry badge, tags,
  updated.
- Certificate detail: metadata (subject, issuer, expiry, fingerprint, SANs), the
  key reference and the env var it reads, and an **SNIs** child group with an
  **Add SNI** button.
- **New certificate** / **New CA certificate** / **Add SNI** forms, all reusing
  the JSON editor and Kong's plan-time schema validation. The certificate form
  is seeded with a `{vault://env/...}` key placeholder, so the accepted shape is
  the default rather than something to discover.
- Deleting a certificate warns that its SNIs go with it — the cascade warning
  M5a added for an upstream's targets, which Kong applies here too.

**REST + MCP**

`Api::V1::ChangePlansController::SUPPORTED_TYPES` is derived from the registry,
so all three types are writable through `kong_plan` the moment they are
registered — no list to update. `kong_apply` gains `acknowledge_env_vars`, and a
new `kong_certs_expiring` tool reads the dashboard's data.

---

## 7. Verification

TDD throughout, as in M5a: a failing test first, watched fail for the right
reason, then the minimal code.

- **Unit:** `CertificateKeyPolicy` (accepted forms, rejected forms, PR-vs-direct,
  env var mapping), `CertificateMetadata` (a real generated PEM, an expired one,
  an unparseable one), `Redactor` (references pass, anything else redacted,
  other entities unaffected), `EntitySync` identity and metadata, `ChangePlanner`
  and `ChangeApplier` policy + acknowledgement.
- **Request:** the three new forms, the expiry dashboard, the review-page
  checkbox, and the API's 422-vs-403 split.
- **Live:** an end-to-end run against a temporary Kong node carrying a real env
  var — create a certificate with a vault-referenced key, attach an SNI,
  **complete a TLS handshake and assert the served certificate is the right
  one**, then tear the node and its entities down. This is the check that proves
  the whole mechanism, and it is the one that found M5a's millisecond bug.

The suite must stay green (328 examples today), RuboCop clean, Brakeman at zero
warnings, and `tsc` clean.

---

## 8. Out of scope

- **decK rendering** for these types — M5c. A PR-mode plan for a certificate,
  SNI or CA certificate raises `NotImplementedError` and stays pending, exactly
  as upstreams and targets do now.
- **Post-apply TLS probing.** Considered and declined: it needs a per-connection
  proxy address and network reach to the proxy. The acknowledgement covers the
  common failure (a typo or a variable nobody set) without new configuration.
- Certificate issuance, renewal, or rotation helpers.
- The CSI Secret Store Driver wiring itself (DESIGN §8 "ทาง ก") — that is
  deployment's job. This tool only emits and displays the reference.
