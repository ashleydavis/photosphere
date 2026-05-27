# Desktop Manual Test: MCP Server Runs From the Desktop App

> **Warning:** Desktop MCP support is not yet implemented. This walkthrough is
> a placeholder so that the manual test exists once MCP support lands.

Test that the desktop app can expose an MCP server and a compatible client can
list its resources.

## Prerequisites

Start the desktop app from source (run from the repo root):

```bash
bun run dev
```

You need an MCP client (for example `mcp-inspector` or a Claude Code
configuration entry) configured to connect to the Photosphere desktop MCP
endpoint.

## Steps

### 1. Open an existing database in the app

1. Open the `test/dbs/50-assets` fixture in the desktop app (see
   `desktop/database/load-50-asset-fixture.md`).

Expected:
- The gallery loads.

---

### 2. Enable / start the MCP server from the app

1. Use the app menu or Settings entry that toggles MCP on.

Expected:
- The app reports the MCP server is listening (in a status indicator, log line, or notification).

---

### 3. Connect with an MCP client

Configure your client to talk to the desktop app's MCP endpoint and list the
exposed resources.

Expected:
- The client lists Photosphere resources (database metadata and assets) without errors.
- Fetching an asset's metadata returns the expected fields for an asset from the loaded fixture.

---

### 4. Disable / stop the MCP server

1. Toggle MCP off in the app.

Expected:
- The endpoint stops accepting connections.
- The next MCP client connection attempt fails (proving the server actually shut down).
