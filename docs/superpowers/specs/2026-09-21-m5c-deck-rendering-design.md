# M5c — decK rendering for every managed type (design)

Follows M5b (certificates, SNIs, CA certificates). Completes M5 by making PR
mode work for every entity type the tool manages, instead of services alone.

**Goal:** a PR-mode apply renders any managed entity into the connection's decK
YAML, preserves everything it does not manage, and refuses to write anything it
cannot render faithfully.

**Not in scope:** opening the pull request itself (host API tokens, webhooks, CI
pipeline wiring). Branch-push behaviour is unchanged — `execute_pr!` still ends
at `pr_state: "branch_pushed"`. That remains its own milestone.

---

## 1. Spike findings — real decK, not documentation

Every fact below was measured against the actual binaries on 2026-09-21, decK
**v1.51.1** (the version `deck_cli.rb` documents) and **v1.66.1** (current).
**Both versions behaved identically on every check**, so the file format
decisions here are not version-sensitive and DESIGN.md's open question 6 can be
closed for this surface.

This section exists because M5b's Task 13 found that a stubbed
`/schemas/certificates/validate` accepted a field real Kong rejects. The same
trap was open here and had already closed on us — see 1.1.

### 1.1 `Kong::DeckCli` has never run, and both its commands are wrong

`Kong::DeckCli` has no spec file. `spec/services/kong/change_applier_spec.rb`
stubs it: `allow(Kong::DeckCli).to receive(:validate).and_return(true)`. The
`deck` binary was not installed on the development machine at all. Nothing has
ever checked that the YAML this tool generates is acceptable to decK.

Two defects, both fatal, both invisible behind the stub:

1. **`-s` is not a valid flag.** Both commands take the state file as a
   positional argument: `deck file validate [flags] [kong-state-files...]`,
   `deck gateway diff [flags] [kong-state-files...]`. The current calls produce
   `Error: unknown shorthand flag: 's' in -s` on both versions.
2. **`deck gateway validate` is an online command.** Its own help: *"Validates
   against the Kong API, via communication with Kong… For offline validation
   see `deck file validate`."* The applier calls it expecting an offline schema
   check before the diff, which is what `deck file validate` does.

### 1.2 decK's schema is closed

| Input | Result on both versions |
| --- | --- |
| unknown top-level key `kongsole_notes:` | `(root): Additional property kongsole_notes is not allowed` |
| unknown field on a service | `services.0: Additional property kongsole_marker is not allowed` |
| top-level `targets:` | `(root): Additional property targets is not allowed` |
| `vaults:`, `consumer_groups:` | accepted |

Arbitrary foreign content cannot be preserved *and* validate. Valid decK keys
the tool does not manage can be, and must be.

### 1.3 Required fields differ per type

| Input | Result |
| --- | --- |
| certificate without `id` | `certificates.0: id is required` |
| ca_certificate without `id` | **accepted** |
| route without `name` | `routes.0: name is required` (and `Must validate at least one schema (anyOf)`) |
| services, routes (named), upstreams, targets, consumers, plugins without ids | accepted |

decK requires Kong's uuid on certificates and only on certificates. This
collides with `Kong::EntityTypes::KONG_MANAGED_FIELDS`, which strips `id` from
everything rendered. Kong's Admin API permits unnamed routes; decK does not.

### 1.4 The nested shape validates

This document passed `deck file validate` on both versions, and is the shape
M5c emits:

```yaml
_format_version: "3.0"
_info:
  select_tags:
    - team-a
services:
  - name: orders
    url: http://orders:80
    routes:
      - name: orders-route
        paths:
          - /orders
        plugins:
          - name: rate-limiting
            config:
              minute: 60
    plugins:
      - name: request-size-limiting
upstreams:
  - name: orders-up
    targets:
      - target: 10.0.0.1:80
        weight: 100
certificates:
  - id: 11111111-2222-3333-4444-555555555555
    cert: |
      -----BEGIN CERTIFICATE-----
      ...
    key: "{vault://env/cert-spike-key}"
    snis:
      - name: spike.example.internal
ca_certificates:
  - cert: |
      -----BEGIN CERTIFICATE-----
      ...
consumers:
  - username: reporting-bot
plugins:
  - name: correlation-id
```

### 1.5 The decK env placeholder is a textual substitution, applied before YAML parsing

With the variable unset, validation fails:
`error calling env: environment variable 'DECK_CERT_SPIKE_KEY' present in state
file but not set`. So unlike a vault reference, a decK placeholder **is**
checked — see section 6.

Because substitution is textual, quoting decides whether the result is valid
YAML at all. Measured:

| Form | decK 1.51 / 1.66 | Ruby `YAML.safe_load` |
| --- | --- | --- |
| `key: "${{ env "X" }}"` | PASS | **unparseable** |
| `key: '${{ env "X" }}'` | **PASS** | **parses** |
| `key: ${{ env "X" }}` (bare) | PASS | parses |
| `key: "${{ env 'X' }}"` | FAIL | parses |
| `key: "{vault://env/…}"` | PASS | parses |

**M5c emits the single-quoted form.** It is the only form both decK and this
tool's own parser accept, which the round-trip guard requires.

A related measurement: substituting a value containing real newlines produces
`error converting YAML to JSON: yaml: line 27: could not find expected ':'`.
A single-line value substitutes cleanly. See section 9 for the risk this leaves
open.

### 1.6 The current renderer silently drops what it does not know

`Kong::DeckRenderer.serialize` emits only `_format_version`, `_info` and
`services`. Parsing a file containing `routes:`, `upstreams:` and `consumers:`
and serializing it returns a document with all three **gone**. Since
`deck gateway sync` deletes anything absent from the file, a PR-mode apply
against a real config repo would propose deleting them — DESIGN.md §1.2's
highest-severity risk.

`verify_round_trip!` cannot catch this: it re-parses the already-truncated
output and compares it against itself, which is self-consistent by
construction. **The guard must run on the input.**

---

## 2. Decisions taken

| Decision | Choice |
| --- | --- |
| Types rendered | service, route, plugin, upstream, target, certificate, sni, ca_certificate, **consumer** (9). Credentials never rendered (DESIGN.md §1.7 — `deck dump` returns password hashes). |
| Foreign content | Preserve, plus a fail-closed guard on the input. |
| Child placement | Nested, matching `deck gateway dump`. §1.3 makes this mandatory for targets. |
| M5c boundary | Renderer only; no PR-host API. |
| decK versions | Verified on 1.51.1 and 1.66.1. |
| Certificate id | Minted client-side when rendering a create. |
| `DeckCli` | Fix both calls, add its first real spec, honour `ENV["DECK_BIN"]`. |

---

## 3. Components

**`Kong::EntityTypes::Definition`** gains the decK facts, keeping the registry
the single source of per-type truth (the M3 pattern that already drives sync,
planner and applier):

- `deck_collection` — top-level list name, or `nil` for a type that only nests
  (`target`, `sni`).
- `deck_parent_collection` — where a nested child lives inside its parent.
- `deck_identity` — a proc returning the value identifying the entity within
  its collection. Per-type quirks live here and nowhere else.

**`Kong::DeckDocument`** (new) owns the file format alone: `parse`, `serialize`,
preservation, and `verify_input!`. Today's `parse`/`serialize` move here,
generalised from one hardcoded collection to all of them, with children emitted
inside their parents.

**`Kong::DeckRenderer`** (existing, narrowed) keeps one public method,
`apply_change(doc, change_plan)`, now resolving location through the registry
rather than hardcoding service-name matching.

**`Kong::DeckCli`** (fixed) — positional file arguments, `deck file validate`
for the offline check, `deck gateway diff` for the online diff, `ENV["DECK_BIN"]`
defaulting to `"deck"`, and a real spec.

**`Kong::ChangeApplier#execute_pr!`** drops the service-only guard. The flow:

```
pull → DeckDocument.parse → verify_input!  ← the drop-bug fix
     → DeckRenderer.apply_change → DeckDocument.serialize
     → write → deck file validate → deck gateway diff → commit → push
```

---

## 4. Placement and identity

| Type | Location in YAML | Identified by |
| --- | --- | --- |
| service | `services[]` | `name` |
| route | `services[].routes[]` | `name` (decK requires) |
| plugin | scope's `plugins[]`; top-level when global | `name` + scope |
| upstream | `upstreams[]` | `name` |
| target | `upstreams[].targets[]` only | `target` (host:port) |
| certificate | `certificates[]` | `id` (decK requires) |
| sni | `certificates[].snis[]` | `name` |
| ca_certificate | `ca_certificates[]` | `id` when present, else cert fingerprint |
| consumer | `consumers[]` | `username` |

These mirror the `logical_key` values `Kong::EntitySync` already computes, so
YAML identity and read-model identity cannot drift apart.

A PR-mode plan for a `keyauth_credential` or `basicauth_credential` raises
`NotImplementedError` with a message stating the exclusion is deliberate.

---

## 5. Preservation and the fail-closed guard

Preservation is two-stage, and the stages have different jobs:

- **Fidelity — ours.** `DeckDocument` keeps every key it parses. `verify_input!`
  refuses to proceed unless `serialize(parse(text))` equals the file byte for
  byte, naming the first line that differs.
- **Legality — decK's.** `deck file validate` decides whether those keys are
  allowed. The tool never encodes decK's schema itself.

A `vaults:` or `consumer_groups:` block the tool does not manage therefore
survives untouched, which §1.2 confirmed validates.

**Four cases fail closed, before anything is written:**

1. The input does not round-trip (comments, anchors, hand formatting).
2. A route with no name (§1.3).
3. A child whose parent is not in the file — nesting leaves it nowhere to go.
4. A certificate update whose YAML entry carries no `id` — nothing can match it.

Each raises before the branch is touched, leaving the repo clean. A failure to
render is always an error, never a silent omission — the same rule M5b applied
to private keys.

---

## 6. Certificates, keys and the acknowledgement

The public `cert` PEM belongs in the YAML. The private key never does: `key` is
always a reference, either `{vault://env/cert-x-key}` or, in PR mode,
`'${{ env "DECK_CERT_X_KEY" }}'` in the single-quoted form §1.5 established.
`Kong::CertificateKeyPolicy` already rejects anything else at plan and apply
time, so the renderer inherits that guarantee rather than re-implementing it.

**The minted certificate id.** When rendering a certificate create, the tool
generates a UUID, writes it as the YAML `id`, and records it on the plan's
`target_kong_id`. Kong accepts client-supplied uuids on create, so the id the
PR proposes is the id Kong ends up with, and every later edit can match the
certificate. The audit event therefore records which certificate a PR proposed.
No migration is required. This is a deliberate, documented exception to
`KONG_MANAGED_FIELDS`, scoped to `id` on `certificate` only.

**The acknowledgement means different things per reference kind, and §1.5 is
why we know:**

- A **vault reference** is checked by nobody. Kong accepts a typo and TLS fails
  later at handshake — the limitation M5b's acknowledgement exists for. PR mode
  keeps requiring it.
- A **decK placeholder** fails `file validate` loudly when the variable is
  unset. That path is self-checking, and the apply surfaces decK's own message.

---

## 7. Error handling

| Condition | Result |
| --- | --- |
| input does not round-trip | `Kong::ChangeGuardrails::Violation`, repo untouched |
| unrenderable entity (unnamed route, missing parent, cert without id) | `Kong::ChangeGuardrails::Violation`, named cause |
| credential in PR mode | `NotImplementedError`, stating the exclusion is deliberate |
| `deck file validate` rejects the document | `Kong::DeckCli::Error` carrying decK's own message |
| `deck` binary missing | `Kong::DeckCli::Error` naming `DECK_BIN` |

Existing mapping is unchanged: a `Violation` is an API 403, `NotImplementedError`
a 422, and the web re-renders with the message. Messages pass through
`Kong::CertificateKeyPolicy.scrub`, as M5b established for every echoed string.

---

## 8. Testing

- **Unit** — `DeckDocument` round-trip properties; golden files pinning the
  serializer's exact bytes per type; each of the four fail-closed cases; the
  drop-bug regression from §1.6 (a document with `routes`, `upstreams` and
  `consumers` must survive a service edit intact).
- **`Kong::DeckCli`** — assert the exact argv, since the defects in §1.1 were
  entirely argv. Plus opt-in tests that run the pinned binary through
  `DECK_BIN`.
- **Live check (the Task 13 equivalent, not optional)** — render all 9 types,
  run real `deck file validate`, then `deck gateway sync` against a throwaway
  Kong node and confirm Kong holds what the YAML claimed. The node shares the
  local Postgres, so the script aborts unless the relevant collections start
  empty and cleans up only what it tagged — the safety amendment M5b's Ruling 15
  established.

---

## 9. Open risk, to be settled by the live check

With the single-quoted placeholder, decK substitutes textually and the quotes
survive, so `\n` escapes in the variable stay literal. Whether Kong then
receives a usable PEM or a mangled one cannot be determined offline — it needs
a real `deck gateway sync`.

If it is mangled, PR mode supports vault references only, the decK placeholder
path is withdrawn for private keys, and both README and
`Kong::CertificateKeyPolicy`'s message say so. That outcome is acceptable: a
vault reference already covers the use case, and M5b made the placeholder
PR-mode-only precisely because it was the less-proven path.

---

## 10. Follow-ups this milestone does not take

Carried from M5b's final review and this spike:

- `expiring_within` does not itself exclude soft-deleted rows.
- A non-Hash `attributes` returns 500 on `POST /api/v1/change_plans`.
- `fields[]=x` returns 500 on the entities API (pre-existing M5a).
- `audit_events.context` is written but not surfaced in the UI or API.
- Real-Kong behaviour still only stubbed: `PATCH /certificates` with a changed
  `snis`, `POST /ca_certificates` validation, an SNI update that re-points its
  certificate. M5c's live check is the natural place for these.
