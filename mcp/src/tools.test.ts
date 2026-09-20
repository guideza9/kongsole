import { describe, it, expect, vi } from "vitest";
import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { KongctlApiError, type KongctlClient } from "./client.js";
import { registerTools } from "./tools.js";

type ToolConfig = { inputSchema?: z.ZodRawShape };

// A minimal fake standing in for McpServer: registerTools only ever calls
// .registerTool(name, config, callback), so that's all this needs to
// capture -- exercising the real mapping/formatting logic in tools.ts
// without spinning up a full SDK server + transport for a unit test. The
// config is kept too, since the SDK validates arguments against its
// inputSchema *before* the callback runs: a field missing from the schema
// is stripped there, and the callback never sees it.
function fakeServer() {
  const tools = new Map<string, (args: unknown) => Promise<unknown>>();
  const configs = new Map<string, ToolConfig>();
  const server = {
    registerTool: (name: string, config: ToolConfig, cb: (args: unknown) => Promise<unknown>) => {
      tools.set(name, cb);
      configs.set(name, config);
    }
  } as unknown as McpServer;
  return { server, tools, configs };
}

describe("registerTools", () => {
  it("kong_connections returns the client's data as pretty-printed text", async () => {
    const { server, tools } = fakeServer();
    const client = { listConnections: vi.fn().mockResolvedValue({ data: [{ name: "dev-readwrite" }] }) } as unknown as KongctlClient;
    registerTools(server, client);

    const result = await tools.get("kong_connections")!({});

    expect(result).toEqual({
      content: [{ type: "text", text: JSON.stringify({ data: [{ name: "dev-readwrite" }] }, null, 2) }]
    });
  });

  it("kong_search passes params straight through to the client", async () => {
    const { server, tools } = fakeServer();
    const searchEntities = vi.fn().mockResolvedValue({ data: [], meta: {} });
    const client = { searchEntities } as unknown as KongctlClient;
    registerTools(server, client);

    await tools.get("kong_search")!({ connection: "dev", type: "service", tags: ["payment"] });

    expect(searchEntities).toHaveBeenCalledWith({ connection: "dev", type: "service", tags: ["payment"] });
  });

  it("kong_plan surfaces a guardrail violation as isError with Rails' exact message", async () => {
    const { server, tools } = fakeServer();
    const planChange = vi.fn().mockRejectedValue(
      new KongctlApiError(403, "admin-api is admin-path/protected -- it can never be deleted via the agent path, no override")
    );
    const client = { planChange } as unknown as KongctlClient;
    registerTools(server, client);

    const result = (await tools.get("kong_plan")!({
      connection: "dev", type: "service", operation: "delete", target_kong_id: "x"
    })) as { content: { type: string; text: string }[]; isError: boolean };

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("no override");
  });

  // A target only exists inside an upstream, so creating one (or a credential
  // inside a consumer) needs parent_kong_id. The REST API has always accepted
  // it; without it in the tool's schema an agent had no way to send it.
  describe("kong_plan parent_kong_id", () => {
    const UPSTREAM = "aaaaaaaa-0000-0000-0000-00000000000a";

    it("is declared in the input schema, so the SDK doesn't strip it before the callback", () => {
      const { server, configs } = fakeServer();
      registerTools(server, {} as unknown as KongctlClient);

      const schema = z.object(configs.get("kong_plan")!.inputSchema!);
      const parsed = schema.parse({
        connection: "dev", type: "target", operation: "create", parent_kong_id: UPSTREAM,
        attributes: { target: "10.0.0.1:8080" }
      });

      expect(parsed.parent_kong_id).toBe(UPSTREAM);
    });

    it("stays optional, so existing service/route calls are unchanged", () => {
      const { server, configs } = fakeServer();
      registerTools(server, {} as unknown as KongctlClient);

      const schema = z.object(configs.get("kong_plan")!.inputSchema!);

      expect(() => schema.parse({ connection: "dev", type: "service", operation: "delete", target_kong_id: "x" })).not.toThrow();
    });

    it("is passed straight through to the client", async () => {
      const { server, tools } = fakeServer();
      const planChange = vi.fn().mockResolvedValue({ id: 1, status: "pending" });
      registerTools(server, { planChange } as unknown as KongctlClient);

      await tools.get("kong_plan")!({
        connection: "dev", type: "target", operation: "create", parent_kong_id: UPSTREAM, attributes: { target: "10.0.0.1:8080" }
      });

      expect(planChange).toHaveBeenCalledWith({
        connection: "dev", type: "target", operation: "create", parent_kong_id: UPSTREAM, attributes: { target: "10.0.0.1:8080" }
      });
    });

    it("tells the agent, in the tool description, when it is needed and which types exist", () => {
      const { server, configs } = fakeServer();
      registerTools(server, {} as unknown as KongctlClient);

      const schema = configs.get("kong_plan")!.inputSchema!;
      const described = JSON.stringify([schema.parent_kong_id?.description, schema.type?.description]);

      expect(described).toContain("target");
      expect(described).toContain("upstream");
    });
  });

  it("kong_apply surfaces the rank>=2 direct-mode block as isError", async () => {
    const { server, tools } = fakeServer();
    const applyChange = vi.fn().mockRejectedValue(new KongctlApiError(403, "connection is rank 2 on apply_mode direct -- PR mode required"));
    const client = { applyChange } as unknown as KongctlClient;
    registerTools(server, client);

    const result = (await tools.get("kong_apply")!({ connection: "uat-direct", plan_id: 1 })) as {
      content: { type: string; text: string }[];
      isError: boolean;
    };

    expect(applyChange).toHaveBeenCalledWith(1, "uat-direct");
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("PR mode");
  });

  it("a plain Error (not KongctlApiError) still surfaces its message rather than throwing", async () => {
    const { server, tools } = fakeServer();
    const client = { listConnections: vi.fn().mockRejectedValue(new Error("unexpected")) } as unknown as KongctlClient;
    registerTools(server, client);

    const result = (await tools.get("kong_connections")!({})) as { isError: boolean; content: { text: string }[] };

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toBe("unexpected");
  });
});
