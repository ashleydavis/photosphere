# Desktop Manual Test: MCP Server Runs From the Desktop App

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

> **Warning:** Desktop MCP support is not yet implemented. This walkthrough is
> a placeholder so that the manual test exists once MCP support lands.

Test that the desktop app can expose an MCP server and a compatible client can
list its resources.

## Prep

Open a terminal at the repo root for the desktop app.

Clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-mcp-server
```

Run this in the same terminal. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-mcp-server/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-mcp-server/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-mcp-server/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-mcp-server/logs
export XDG_DATA_HOME=/tmp/psi-desktop-mcp-server/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-mcp-server/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

Start the desktop app in the same terminal, from the repo root. Use the script for the platform you are on: `bun run linux`, `bun run macos` or `bun run windows`. It keeps running for the whole test:

```bash
bun run linux
```

You need an MCP client (for example `mcp-inspector` or a Claude Code
configuration entry) configured to connect to the Photosphere desktop MCP
endpoint.

Expected:
- The cleanup prints nothing.
- The desktop app window opens.

## Test

### 1. Open an existing database in the app

1. Open the `test/dbs/50-assets` fixture in the desktop app (see
   `desktop/database/load-50-asset-fixture.md`).

Expected:
- The gallery loads.

---

### 2. Check that the MCP server started with the app

The MCP server starts by itself when the app starts; there is no control to turn it on. Find its port in the app's log, in the CLI terminal:

```bash
grep -h "MCP server initialized" /tmp/psi-desktop-mcp-server/logs/logs/*.log
```

Expected:
- One line, `MCP server initialized on port <port>`. Record `<port>`: the endpoint is `http://127.0.0.1:<port>/mcp`.

## Check

### 3. Connect with an MCP client

The server offers its features as MCP tools, not resources. In the CLI terminal, with the `<port>` from step 2, list the tools and then fetch an asset's metadata from the loaded fixture:

```bash
curl -s -X POST http://127.0.0.1:<port>/mcp -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
curl -s -X POST http://127.0.0.1:<port>/mcp -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_media_file_info","arguments":{"assetId":"63e9c63b-9164-6376-13e9-ef5500000000"}}}'
```

Expected:
- The tool list includes `list_databases`, `get_database_summary`, `list_media_files` and `get_media_file_info`, with no error.
- `get_media_file_info` returns the asset's metadata without an error: `origFileName` `WWEFneQ5XAk.jpg`, `contentType` `image/jpeg`, `width` 5464, `height` 8192.

---

### 4. Check that the MCP server stops with the app

The MCP server stops only when the app quits; there is no control to turn it off.

1. Quit the desktop app.
2. In the CLI terminal, try to connect to the endpoint, with the `<port>` from step 2:

```bash
curl -s -X POST http://127.0.0.1:<port>/mcp -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'; echo "exit $?"
```

Expected:
- The endpoint stops accepting connections: `curl` prints nothing and the last line is `exit 7` (could not connect), proving the server shut down.
