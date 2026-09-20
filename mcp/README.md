# kongctl-mcp

MCP stdio server for the Kong CE control plane (`docs/DESIGN.md` §12). A
thin client over the PAT-secured `/api/v1` REST API the Rails app already
serves — this package holds no Kong credentials and no business logic;
every guardrail (write-access, admin-path protection, rank≥2 direct-mode
apply) lives server-side and this just relays its exact error messages.

## Tools

| Tool | REST call |
|---|---|
| `kong_connections` | `GET /connections` |
| `kong_search` | `GET /entities` |
| `kong_plan` | `POST /change_plans` |
| `kong_apply` | `POST /change_plans/:id/apply` |

## Setup

```bash
npm install
npm run build
```

Requires two environment variables:

- `KONGCTL_TOKEN` — a personal access token, issued from the Kongsole web
  UI at `/personal_access_tokens`. Only reaches connections with a stored
  credential (`credential_mode: stored`); the token is bound to a fixed
  set of connections at issue time.
- `KONGCTL_API_URL` — base URL of the Rails app's API, e.g.
  `http://localhost:3000/api/v1`. Defaults to that value if unset.

## Adding it to an MCP client

```json
{
  "mcpServers": {
    "kongctl": {
      "command": "node",
      "args": ["/absolute/path/to/kong_integration/mcp/dist/index.js"],
      "env": {
        "KONGCTL_TOKEN": "kctl_...",
        "KONGCTL_API_URL": "http://localhost:3000/api/v1"
      }
    }
  }
}
```

## Development

```bash
npm test           # vitest, no live Rails needed -- fetch is stubbed
npm run build       # tsc -> dist/
npm start           # node dist/index.js (needs KONGCTL_TOKEN set)
```
