// Minimal health check that spawns the Browser Control MCP server via stdio
// and calls the `get-list-of-open-tabs` tool.
//
// Usage:
//   1) Edit EXTENSION_SECRET and SERVER_PATH below.
//   2) Run:  node docs/mcp/scripts/health-check.mjs
//
// Requires: npm i @modelcontextprotocol/sdk zod

import { McpClient } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

// EDIT THESE FOR YOUR MACHINE
const EXTENSION_SECRET = process.env.EXTENSION_SECRET || "<paste_secret_from_firefox_extension>";
const EXTENSION_PORT = process.env.EXTENSION_PORT || "8089";
const SERVER_PATH = process.env.BROWSER_MCP_SERVER || "E:/GitHub/browser-control-mcp/mcp-server/dist/server.js";

async function main() {
  if (!EXTENSION_SECRET || EXTENSION_SECRET.startsWith("<paste_")) {
    console.error("Please set EXTENSION_SECRET env var or edit this file.");
    process.exit(1);
  }

  const transport = new StdioClientTransport({
    command: "node",
    args: [SERVER_PATH],
    env: {
      EXTENSION_SECRET,
      EXTENSION_PORT,
    },
  });

  const client = new McpClient(transport);
  await client.connect();

  const tools = await client.listTools();
  console.log("Available tools:", tools.tools.map((t) => t.name));

  const result = await client.callTool("get-list-of-open-tabs", {});
  console.log("get-list-of-open-tabs result:");
  for (const c of result.content) {
    if (c.type === "text") console.log("-", c.text);
  }

  await client.close();
}

main().catch((err) => {
  console.error("Health check failed:", err);
  process.exit(1);
});

