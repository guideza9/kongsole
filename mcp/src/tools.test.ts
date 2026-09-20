import { describe, it, expect, vi } from "vitest";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { KongctlApiError, type KongctlClient } from "./client.js";
import { registerTools } from "./tools.js";

// A minimal fake standing in for McpServer: registerTools only ever calls
// .registerTool(name, config, callback), so that's all this needs to
// capture -- exercising the real mapping/formatting logic in tools.ts
// without spinning up a full SDK server + transport for a unit test.
function fakeServer() {
  const tools = new Map<string, (args: unknown) => Promise<unknown>>();
  const server = {
    registerTool: (name: string, _config: unknown, cb: (args: unknown) => Promise<unknown>) => {
      tools.set(name, cb);
    }
  } as unknown as McpServer;
  return { server, tools };
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
