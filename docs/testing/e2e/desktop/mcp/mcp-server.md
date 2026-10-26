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

### 2. Enable / start the MCP server from the app

1. Use the app menu or Settings entry that toggles MCP on.

Expected:
- The app reports the MCP server is listening (in a status indicator, log line, or notification).

## Check

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
