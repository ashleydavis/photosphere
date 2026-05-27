# CLI Manual Test: MCP Server Starts And Serves Resources

> **Warning:** The `psi mcp` command is not yet implemented. This walkthrough
> is a placeholder so that the manual test exists once MCP support lands.

Test that the CLI can launch an MCP server and a compatible client can list
its resources.

## Prerequisites

Navigate to the CLI source directory:

```bash
cd apps/cli/
```

You need an MCP client (for example, `mcp-inspector` or a Claude Code
configuration entry) configured to launch the Photosphere CLI as an MCP
process.

## Steps

### 1. Clean up any previous test run

```bash
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/db --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/db --yes
```

---

### 2. Start the MCP server

```bash
bun run start -- mcp --db /tmp/psi-test/db
```

Expected:
- The CLI starts the MCP server and waits for client connections.

---

### 3. Connect with an MCP client

Configure the client to launch the same command. List the server's resources.

Expected:
- The client lists Photosphere resources (assets, database metadata) without errors.
- Listing an asset's metadata returns the expected fields for the asset added in step 1.
