import type { Config } from "./config.js";

// One place that talks to Rails, so tools.ts has one place to format
// errors consistently. Every non-2xx response is turned into a
// KongctlApiError carrying the exact message Rails sent back
// (docs/DESIGN.md section 10/12's own guardrail messages -- "no override",
// "this credential can't write", etc.) rather than a generic failure.
export class KongctlApiError extends Error {
  constructor(
    public readonly status: number,
    message: string
  ) {
    super(message);
    this.name = "KongctlApiError";
  }
}

export interface SearchEntitiesParams {
  connection: string;
  type: string;
  q?: string;
  tags?: string[];
  tags_any?: string[];
  tags_none?: string[];
  created_after?: string;
  created_before?: string;
  updated_after?: string;
  updated_before?: string;
  sort?: string;
  limit?: number;
  cursor?: string;
  fields?: string;
}

export interface PlanChangeParams {
  connection: string;
  type: string;
  operation: "create" | "update" | "delete";
  target_kong_id?: string;
  attributes?: Record<string, unknown>;
}

export class KongctlClient {
  constructor(private readonly config: Config) {}

  listConnections(): Promise<unknown> {
    return this.request("GET", "/connections");
  }

  searchEntities(params: SearchEntitiesParams): Promise<unknown> {
    const query = new URLSearchParams();
    for (const [key, value] of Object.entries(params)) {
      if (value === undefined) continue;
      if (Array.isArray(value)) {
        for (const item of value) query.append(`${key}[]`, String(item));
      } else {
        query.set(key, String(value));
      }
    }
    return this.request("GET", `/entities?${query.toString()}`);
  }

  planChange(params: PlanChangeParams): Promise<unknown> {
    return this.request("POST", "/change_plans", params);
  }

  applyChange(planId: number, connection: string): Promise<unknown> {
    return this.request("POST", `/change_plans/${planId}/apply`, { connection });
  }

  private async request(method: string, path: string, body?: unknown): Promise<unknown> {
    let response: Response;
    try {
      response = await fetch(`${this.config.apiUrl}${path}`, {
        method,
        headers: {
          Authorization: `Bearer ${this.config.token}`,
          ...(body ? { "Content-Type": "application/json" } : {})
        },
        body: body ? JSON.stringify(body) : undefined
      });
    } catch (cause) {
      const reason = cause instanceof Error ? cause.message : String(cause);
      throw new KongctlApiError(0, `could not reach the Kongsole API at ${this.config.apiUrl}: ${reason}`);
    }

    const json = await response.json().catch(() => null);

    if (!response.ok) {
      const message = (json as { error?: string } | null)?.error ?? `request failed with status ${response.status}`;
      throw new KongctlApiError(response.status, message);
    }

    return json;
  }
}
