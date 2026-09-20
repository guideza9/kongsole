import { describe, it, expect } from "vitest";
import { loadConfig } from "./config.js";

describe("loadConfig", () => {
  it("throws a clear error when KONGCTL_TOKEN is missing", () => {
    expect(() => loadConfig({})).toThrow(/KONGCTL_TOKEN is required/);
  });

  it("defaults apiUrl to localhost:3000 and strips a trailing slash", () => {
    const config = loadConfig({ KONGCTL_TOKEN: "kctl_x" });
    expect(config.apiUrl).toBe("http://localhost:3000/api/v1");

    const withSlash = loadConfig({ KONGCTL_TOKEN: "kctl_x", KONGCTL_API_URL: "https://kongctl.example/api/v1/" });
    expect(withSlash.apiUrl).toBe("https://kongctl.example/api/v1");
  });
});
