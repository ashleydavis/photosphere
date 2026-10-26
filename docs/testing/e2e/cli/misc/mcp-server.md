# CLI Manual Test: MCP Server Starts And Serves Tools

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `psi mcp` starts an MCP server over stdio and that a client can open a database and list its media files through the server's tools.

The server does not exit when its stdin closes, so each step below wraps it in `timeout 30`. The server does not take `--db`. The client picks the database at runtime with the `open_database` tool. The steps below act as the client by writing MCP JSON-RPC messages to the server's stdin; an MCP client such as `mcp-inspector`, set up to launch `bun run index.ts mcp` from `apps/cli/`, can be used instead.

## Prep

Move into the CLI source directory, clean up any previous test run, and create a database holding one file:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
bun run start -- init --db /tmp/psi-test/db --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/db --yes
```

Expected:
- The database is created and the file is reported as added.

## Test

### 1. Start the server and list its tools

```bash
{ printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"manual-test","version":"0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'; sleep 6; } \
    | timeout 30 bun run index.ts mcp 2>/dev/null | jq -c '{id, tools: [.result.tools[]?.name]}'
```

Expected:
- A reply with `id` 1 (the server's initialize response) and a reply with `id` 2.
- The `id` 2 tools include `list_databases`, `open_database`, `list_media_files` and `get_media_file_info`.

---

### 2. Open the database and list its media files

```bash
{ printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"manual-test","version":"0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"open_database","arguments":{"path":"/tmp/psi-test/db"}}}'; sleep 6; \
  printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_media_files","arguments":{}}}'; sleep 6; } \
    | timeout 30 bun run index.ts mcp 2>/dev/null | jq -c 'select(.id==2 or .id==3) | {id, text: .result.content[0].text}'
```

Expected:
- The `id` 2 reply says `Opened database at /tmp/psi-test/db`.
- The `id` 3 reply lists one media file with `origFileName` `test.jpg` and `contentType` `image/jpeg`.

## Check

The replies in steps 1 and 2 are the check.
