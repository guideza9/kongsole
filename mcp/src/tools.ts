import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { KongctlApiError, KongctlClient } from "./client.js";

// A successful call renders the JSON Rails returned as pretty-printed
// text -- the REST layer already does the token-savings work (kong_search's
// summary fields, an explicit `fields=` to narrow further per
// docs/DESIGN.md section 12), so there is nothing to trim here.
function ok(data: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
}

// A failed call surfaces Rails' own message verbatim -- the guardrail
// violation text ("no override", "can't write", "PR mode", ...) is the
// whole point of the message, not an implementation detail to hide behind
// a generic "tool call failed."
function fail(error: unknown) {
  const message = error instanceof KongctlApiError ? error.message : error instanceof Error ? error.message : String(error);
  return { content: [{ type: "text" as const, text: message }], isError: true };
}

// R1.6: a connection is named "project/env" -- a bare env name is ambiguous
// across projects and the API refuses it. Required, with no default, on every
// tool that acts on one (docs/DESIGN.md section 12, guardrail #1).
const CONNECTION = z
  .string()
  .describe('Connection as "project/env", e.g. "project-a/uat" (required, no default; kong_connections lists them)');

export function registerTools(server: McpServer, client: KongctlClient): void {
  server.registerTool(
    "kong_connections",
    {
      title: "List Kong connections",
      description:
        "List every Kong connection this token can reach by its project/env name -- the name every other tool " +
        "takes as `connection` -- with its project, env, rank, apply_mode (null = not set, nothing can be written) and access_level."
    },
    async () => {
      try {
        return ok(await client.listConnections());
      } catch (error) {
        return fail(error);
      }
    }
  );

  server.registerTool(
    "kong_search",
    {
      title: "Search Kong entities",
      description:
        "Filter/sort/paginate synced Kong entities for one connection (docs/DESIGN.md section 9). " +
        "Pass fields= to narrow the response and save tokens.",
      inputSchema: {
        connection: CONNECTION,
        type: z
          .string()
          .describe(
            'Entity type, e.g. "service", "route", "consumer", "plugin", "upstream" or "target" ' +
              "(a target's name is its host:port)"
          ),
        q: z.string().optional().describe("Substring match on name"),
        tags: z.array(z.string()).optional().describe("Must have every one of these tags"),
        tags_any: z.array(z.string()).optional().describe("Must have at least one of these tags"),
        tags_none: z.array(z.string()).optional().describe("Must have none of these tags"),
        created_after: z.string().optional(),
        created_before: z.string().optional(),
        updated_after: z.string().optional(),
        updated_before: z.string().optional(),
        sort: z.string().optional().describe('e.g. "-updated_at" (default), "name"'),
        limit: z.number().int().positive().optional(),
        cursor: z.string().optional().describe("Opaque next_cursor from a previous call's meta"),
        fields: z.string().optional().describe('Comma-separated field allowlist, e.g. "id,name,tags,updated_at"')
      }
    },
    async (params) => {
      try {
        return ok(await client.searchEntities(params));
      } catch (error) {
        return fail(error);
      }
    }
  );

  server.registerTool(
    "kong_certs_expiring",
    {
      title: "List expiring certificates",
      description:
        "Certificates and CA certificates that expire within a window, expired ones included, soonest first, across " +
        "every connection this token can reach (or one, with connection=). Reads the last sync -- check meta.generated_at " +
        "and sync first if it might be stale. Never returns a key or a PEM.",
      inputSchema: {
        days: z.number().int().positive().max(3650).optional().describe("Window in days, 1-3650 (default 30)"),
        connection: z
          .string()
          .optional()
          .describe('Limit to one connection this token is bound to, as "project/env", e.g. "project-a/uat"')
      }
    },
    async (params) => {
      try {
        return ok(await client.certsExpiring(params));
      } catch (error) {
        return fail(error);
      }
    }
  );

  server.registerTool(
    "kong_plan",
    {
      title: "Propose a Kong entity change",
      description:
        "Propose a create/update/delete against a Kong entity. No side effect on Kong -- returns a diff and a " +
        "plan_id for kong_apply to execute. Deleting an admin-path or protected entity is always rejected here, " +
        "with no override. A certificate's key must be a {vault://env/NAME} reference -- a private key is never accepted.",
      inputSchema: {
        connection: CONNECTION,
        type: z
          .string()
          .describe(
            "Entity type: service, route, consumer, plugin, keyauth_credential, basicauth_credential, " +
              "upstream, target, certificate, sni, or ca_certificate"
          ),
        operation: z.enum(["create", "update", "delete"]),
        target_kong_id: z.string().optional().describe("Required for update/delete; omit for create"),
        parent_kong_id: z
          .string()
          .optional()
          .describe(
            "Required to CREATE a target (the upstream's kong id), a credential (the consumer's kong id) or an SNI (the certificate's kong id). " +
              "For update/delete of an existing target it may be omitted -- it is looked up from the last sync."
          ),
        attributes: z.record(z.string(), z.unknown()).optional().describe("Fields to set, required for create/update")
      }
    },
    async (params) => {
      try {
        return ok(await client.planChange(params));
      } catch (error) {
        return fail(error);
      }
    }
  );

  server.registerTool(
    "kong_apply",
    {
      title: "Apply a proposed Kong entity change",
      description:
        "Execute a pending plan from kong_plan against Kong. Rejected outright, before touching Kong, if the " +
        "connection is rank >= 2 and still on apply_mode direct (agent writes to those need PR mode).",
      inputSchema: {
        connection: CONNECTION,
        plan_id: z.number().int().describe("The id kong_plan returned"),
        acknowledge_env_vars: z
          .boolean()
          .optional()
          .describe(
            "Required to apply a certificate whose key is a {vault://env/NAME} reference: pass true only after confirming " +
              "the variable (e.g. CERT_PAYMENTS_KEY) is set on every Kong node. Kong won't notice if it is missing."
          )
      }
    },
    async ({ connection, plan_id, acknowledge_env_vars }) => {
      try {
        return ok(
          acknowledge_env_vars
            ? await client.applyChange(plan_id, connection, true)
            : await client.applyChange(plan_id, connection)
        );
      } catch (error) {
        return fail(error);
      }
    }
  );
}
