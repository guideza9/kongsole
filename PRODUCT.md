# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

Rails 8 backend, Hotwire (Turbo Frames/Streams) + Stimulus + ViewComponent + Tailwind for the human UI, TypeScript MCP SDK (stdio transport, `mcp/`, ~350 lines) for the agent surface. Locked in `docs/DESIGN.md` rev 4 (2026-08-28); not yet scaffolded as code.

## Users

Primary users are the internal platform/infrastructure team operating Kong Gateway CE day to day — the people who create/edit services, routes, consumers, plugins, upstreams, targets, certificates, and SNIs, and who review and merge the PRs the tool produces for uat/prod changes.

A second, equally real user is Claude Code acting as an agent through the MCP server, using the exact same backend, validation, and audit trail as the human UI rather than a separate code path.

Not customer-facing; no external/end-user audience.

## Product Purpose

A control plane for Kong Gateway Community Edition that lets a human (via web UI) and an AI agent (via MCP) manage Kong entities through one shared Rails backend, validation layer, and audit trail — so the two surfaces can never drift apart in what they allow or record.

Success means: the team can safely inspect and change Kong CE state (directly in dev/sit, via reviewed decK PRs in uat/prod) without ever being able to lock itself out of the Admin API, without leaking secrets into the read-model/git/MCP, and with every change attributable to a person even when credentials are shared.

Not yet deployed — currently for internal team use only while M0–M6 are built out (see Capabilities and Constraints).

## Positioning

The Admin API itself is fronted by Kong (loopback pattern: service → `127.0.0.1:8001` + route + basic-auth), which means the tool's own entry path is a Kong entity the tool can see and edit — a self-referential hazard most Kong tooling doesn't have to reason about. The product's core mechanism is treating that admin path as a first-class, protected object (`is_admin_path` guard, reserved `kong-admin-path` tag, absolute delete/write protections, exclusion from rendered decK YAML) rather than an assumption baked into deployment scripts.

A second differentiator: one backend serves both the human UI and the Claude Code MCP agent, so agent-initiated changes go through the identical plan → guardrail → review → apply → audit pipeline a human uses — no separate, looser code path for automation.

A third: drift is tracked across four independent sources (cache vs Kong, Kong vs git in PR-mode envs, git vs Kong post-merge, and Kong's own access log vs recorded change_plans), the last of which catches direct `curl` access to Kong that bypasses the tool entirely.

## Operating Context

- Kong Gateway 3.x, multi-node from day one, CE only (no Enterprise features — e.g. no AKV vault backend, only `env`).
- decK is already in use by the team for GitOps-style config management; this tool must coexist with it, not replace it, and must never let `deck gateway sync` delete the admin path (an explicitly named highest-severity risk).
- Environments are ranked dev(0) / sit(1) / uat(2) / prod(3). dev/sit use direct apply against Kong's Admin API; uat/prod use a PR-based flow (open PR → CI runs `deck gateway validate`/`diff` + a gate blocking any PR touching `kong-admin-path` entities → CAB review → merge → CI `deck gateway sync`).
- Prod (and generally uat) Admin API access for the tool is enforced read-only at the Kong gateway layer itself (separate ro route/host), not just in application logic — a write attempt returns a Kong router 404, which the tool must recognize and report as "this credential can't write," not "not found."
- Credentials for Kong Admin API login *are* the tool's login — there is no separate user database. Both personal and shared/team credentials exist in practice; the tool detects which kind via a `shared-credential` tag on the Kong consumer and requires an `operator` be recorded whenever a shared credential is used to write.
- decK YAML must always be generated from the git-tracked source (never from `deck dump`, which can leak hashed credentials and produce spurious diffs from key reordering).

## Capabilities and Constraints

**In scope (design locked, rev 4):** services, routes, consumers, plugins, upstreams, targets, certificates, SNIs. Keyset pagination from the start. Multi-node from day one. Direct apply for dev/sit; PR/decK apply for uat/prod. MCP tools: `kong_connections`, `kong_search`, `kong_get`, `kong_schema`, `kong_diff`, `kong_drift`, `kong_certs_expiring`, `kong_audit` (read); `kong_plan`, `kong_apply` (write); `kong_export`.

**Hard constraints:**
- Admin-path entities (service/route/plugin/consumer that form the tool's own route into Kong) can never be deleted via MCP (no override) and require typed confirmation to delete via UI; they are never rendered into decK YAML output.
- Secrets (certificate private keys, basic-auth/key-auth credentials) are redacted before ever being written to the read-model, and are never returned by any API, including MCP, with no flag to unredact.
- `Authorization` headers must never appear in logs.
- Non-localhost connections must use `https://`; skipping that is a config-file-only override, never a UI checkbox.

**Explicitly open / undecided (from `docs/DESIGN.md` §17, pending team verification before the milestone named):**
- Before M0: whether the admin route is already split rw/ro (two hosts vs. pre-function plugin fallback), how the current admin path was bootstrapped (Helm/declarative/manual), which consumers are shared credentials needing the `shared-credential` tag.
- Before M2: git host (GitHub/GitLab/Azure DevOps/Bitbucket undecided), whether a config repo already exists and how much of prod is already deck-managed, which decK version/command (`deck sync` vs `deck gateway sync`).
- Before M5: where certificate private keys currently live (inline in Kong, env var, or already in a vault), which determines the ENV-var-vault vs. CSI-driver approach (design doc §8).

**Delivery status:** Not yet deployed; being built for internal team use first. Planned milestones M0 (foundation + connection + admin-path guard) through M6 (drift + hardening), ~8–9 weeks total, usable internally from the end of M2 (decK PR mode) onward.

## Evidence on Hand

`docs/DESIGN.md` (rev 4, 2026-08-28) is the authoritative, team-confirmed solution design and the primary evidence source for this file — it contains the locked decisions table, full data model, API contract, MCP tool list, security model, and an 8–9 week milestone plan. `docs/DESIGN.html` is a rendered "read mode" presentation of that same document, not a product UI mockup.

No screenshots, mockups, real customer data, testimonials, or case studies exist yet. `docs/UI-DESIGN.md` records the app's visual design system (quiet minimalist console — near-white ground, near-black ink, one steel-blue accent, hairline borders, flat dot-chip status badges); DESIGN.html's styling is a document-reading theme, not the app's design language.

## Product Principles

- The tool must never be able to lock the team out of the Admin API it depends on — every feature that could touch the admin path (delete, decK sync, YAML render) is guarded, not just documented.
- Human and agent (MCP) surfaces share one backend, one validation layer, and one audit trail — never a parallel, looser path for automation.
- Higher environments trade speed for safety: uat/prod changes go through PR + CAB review with a Kong-enforced read-only credential, so the write boundary exists even if the application layer has a bug.
- Attribution survives shared credentials: every write traces to a person via `operator`, and Kong's own access log serves as an audit layer outside the tool's control.
- Secrets never leave Kong un-redacted, in any surface (read-model, git, MCP, logs).

## Accessibility & Inclusion

No formal accessibility standard has been mandated; this is an internal-only operational tool for the platform/infra team.
