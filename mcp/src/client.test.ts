import { describe, it, expect, vi, afterEach } from "vitest";
import { KongctlApiError, KongctlClient } from "./client.js";

const config = { apiUrl: "http://localhost:3000/api/v1", token: "kctl_test" };

function stubFetch(status: number, body: unknown) {
  const fetchMock = vi.fn().mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
    json: async () => body
  });
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("KongctlClient", () => {
  it("listConnections sends a Bearer-authed GET to /connections", async () => {
    const fetchMock = stubFetch(200, { data: [{ name: "dev-readwrite" }] });
    const client = new KongctlClient(config);

    const result = await client.listConnections();

    expect(fetchMock).toHaveBeenCalledWith(
      "http://localhost:3000/api/v1/connections",
      expect.objectContaining({ method: "GET", headers: expect.objectContaining({ Authorization: "Bearer kctl_test" }) })
    );
    expect(result).toEqual({ data: [{ name: "dev-readwrite" }] });
  });

  it("searchEntities serializes array params as repeated bracketed keys", async () => {
    const fetchMock = stubFetch(200, { data: [] });
    const client = new KongctlClient(config);

    await client.searchEntities({ connection: "dev", type: "service", tags: ["payment", "core"], limit: 3 });

    const url = fetchMock.mock.calls[0][0] as string;
    expect(url).toContain("connection=dev");
    expect(url).toContain("type=service");
    expect(url).toContain("tags%5B%5D=payment");
    expect(url).toContain("tags%5B%5D=core");
    expect(url).toContain("limit=3");
  });

  it("planChange carries parent_kong_id in the JSON body", async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 201, json: async () => ({ id: 1 }) });
    vi.stubGlobal("fetch", fetchMock);
    const client = new KongctlClient({ apiUrl: "http://rails.test/api/v1", token: "t" });

    await client.planChange({
      connection: "dev", type: "target", operation: "create", parent_kong_id: "up-1", attributes: { target: "10.0.0.1:8080" }
    });

    const [, init] = fetchMock.mock.calls[0];
    expect(JSON.parse(init.body)).toMatchObject({ type: "target", parent_kong_id: "up-1" });
  });

  it("planChange POSTs a JSON body", async () => {
    const fetchMock = stubFetch(201, { id: 1, status: "pending" });
    const client = new KongctlClient(config);

    const result = await client.planChange({
      connection: "dev", type: "service", operation: "update", target_kong_id: "abc", attributes: { tags: ["x"] }
    });

    const [, options] = fetchMock.mock.calls[0];
    expect(options.method).toBe("POST");
    expect(JSON.parse(options.body)).toEqual({
      connection: "dev", type: "service", operation: "update", target_kong_id: "abc", attributes: { tags: ["x"] }
    });
    expect(result).toEqual({ id: 1, status: "pending" });
  });

  it("applyChange POSTs to /change_plans/:id/apply with the connection name", async () => {
    const fetchMock = stubFetch(200, { id: 1, status: "applied" });
    const client = new KongctlClient(config);

    await client.applyChange(1, "dev-readwrite");

    expect(fetchMock).toHaveBeenCalledWith(
      "http://localhost:3000/api/v1/change_plans/1/apply",
      expect.objectContaining({ method: "POST", body: JSON.stringify({ connection: "dev-readwrite" }) })
    );
  });

  it("throws KongctlApiError with Rails' own message on a non-2xx response", async () => {
    stubFetch(403, { error: "admin-api is admin-path/protected -- it can never be deleted via the agent path, no override" });
    const client = new KongctlClient(config);

    await expect(client.planChange({ connection: "dev", type: "service", operation: "delete", target_kong_id: "x" }))
      .rejects.toMatchObject({
        constructor: KongctlApiError,
        status: 403,
        message: expect.stringContaining("no override")
      });
  });

  it("throws a KongctlApiError when the network request itself fails", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("ECONNREFUSED")));
    const client = new KongctlClient(config);

    await expect(client.listConnections()).rejects.toMatchObject({
      constructor: KongctlApiError,
      message: expect.stringContaining("could not reach the Kongsole API")
    });
  });

  it("certsExpiring sends a Bearer-authed GET with days and connection as query params", async () => {
    const fetchMock = stubFetch(200, { data: [], meta: {} });
    const client = new KongctlClient(config);

    await client.certsExpiring({ days: 14, connection: "prod" });

    expect(fetchMock).toHaveBeenCalledWith(
      "http://localhost:3000/api/v1/certificates/expiring?days=14&connection=prod",
      expect.objectContaining({ method: "GET" })
    );
  });

  it("certsExpiring with no arguments sends no query string", async () => {
    const fetchMock = stubFetch(200, { data: [] });

    await new KongctlClient(config).certsExpiring();

    expect(fetchMock.mock.calls[0][0]).toBe("http://localhost:3000/api/v1/certificates/expiring");
  });

  it("applyChange sends acknowledge_env_vars only when it is asked for", async () => {
    const fetchMock = stubFetch(200, { status: "applied" });
    const client = new KongctlClient(config);

    await client.applyChange(1, "dev");
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({ connection: "dev" });

    await client.applyChange(2, "dev", true);
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toEqual({ connection: "dev", acknowledge_env_vars: true });
  });
});
