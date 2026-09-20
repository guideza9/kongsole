#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { loadConfig } from "./config.js";
import { KongctlClient } from "./client.js";
import { registerTools } from "./tools.js";

async function main() {
  const config = loadConfig();
  const client = new KongctlClient(config);

  const server = new McpServer({
    name: "kongctl",
    version: "0.1.0"
  });

  registerTools(server, client);

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((error) => {
  console.error(`kongctl-mcp failed to start: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
});
