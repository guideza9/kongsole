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

export function registerTools(server: McpServer, client: KongctlClient): void {
  server.registerTool(
    "kong_connections",
    {
      title: "List Kong connections",
      description: "List every Kong connection this token can reach, with its env, apply_mode, and access_level."
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
        connection: z.string().describe("Connection name (required, no default -- see section 12's guardrail #1)"),
        type: z.string().describe('Entity type, e.g. "service" (only type synced as of M1)'),
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
    "kong_plan",
    {
      title: "Propose a Kong entity change",
      description:
        "Propose a create/update/delete against a Kong entity. No side effect on Kong -- returns a diff and a " +
        "plan_id for kong_apply to execute. Deleting an admin-path or protected entity is always rejected here, " +
        "with no override.",
      inputSchema: {
        connection: z.string(),
        type: z.string().describe('Entity type, e.g. "service"'),
        operation: z.enum(["create", "update", "delete"]),
        target_kong_id: z.string().optional().describe("Required for update/delete; omit for create"),
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
        connection: z.string(),
        plan_id: z.number().int().describe("The id kong_plan returned")
      }
    },
    async ({ connection, plan_id }) => {
      try {
        return ok(await client.applyChange(plan_id, connection));
      } catch (error) {
        return fail(error);
      }
    }
  );
}
