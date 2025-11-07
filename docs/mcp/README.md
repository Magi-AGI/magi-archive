# Browser Control MCP – Integration Guide

This guide shows how to install the Browser Control MCP server and wire it into MCP‑aware CLIs (Codex, Claude Desktop, etc.), plus a quick health check.

## Prerequisites
- Node.js 22+
- Firefox (or Developer Edition)
- The Browser Control repo: E:\GitHub\browser-control-mcp (adjust paths if different)

## Install and Build
1) Build server + extension
   - In `E:\GitHub\browser-control-mcp`:
     - `npm install`
     - `npm run build`
2) Install the Firefox extension
   - AMO: see repository README, or load temporary add‑on via `about:debugging` → Load `firefox-extension/manifest.json`
   - Copy the extension secret from its options page

## Configure MCP Server (stdio)
- Command: `node`
- Args: `E:\GitHub\browser-control-mcp\mcp-server\dist\server.js`
- Env:
  - `EXTENSION_SECRET`: value from the extension options page
  - `EXTENSION_PORT`: `8089` (optional, default 8089)

Examples are provided in:
- `docs/mcp/clients/codex.mcp.example.json`
- `docs/mcp/clients/claude_desktop_config.example.json`

## Health Check (optional)
Use `docs/mcp/scripts/health-check.mjs` to spawn the server and call `get-list-of-open-tabs`.
- Edit the placeholders (server path, secret) and run:
  - `node docs/mcp/scripts/health-check.mjs`

## Notes
- The server only connects locally to the Firefox extension using a shared secret.
- Reading page content requires explicit per‑domain consent in the extension.
- For Docker usage and DXT packaging, follow the browser-control repository README.

