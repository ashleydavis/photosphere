#!/bin/bash

# Drives the desktop MCP server end to end over its Streamable HTTP route. Each tool call travels from the server to the page as an
# mcp-tool-request event, is answered by the page's tool handler on the mcp-tool-response channel, and comes back as the HTTP reply. The
# scenario speaks the protocol with curl: initialize, tools/list, then tools/call for tools that only the page can answer
# (list_databases from the configured list, get_database_summary from the open database).

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 60 "mcp-server"

case "$PLATFORM" in
    android|ios)
        log_info "SKIP: a phone has no MCP server. Skipping."
        exit 77
        ;;
esac

trap 'cleanup_apps "$TMP_DIR"' EXIT

DATABASE_PATH="$TMP_DIR/mcp-db"
log_info "Pre-creating the database with the CLI..."
create_database "$DATABASE_PATH" "$REPO_DIR/test/test.png" "$REPO_DIR/test/test.jpg"

# The configured list is what list_databases reports, so it is written to the config file before the app starts.
mkdir -p "$TMP_DIR/config"
cat > "$TMP_DIR/config/databases.toml" <<TOML
[[databases]]
name = "McpDatabase"
description = ""
path = "$DATABASE_PATH"
TOML

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# In test mode the server binds a free port and logs it.
wait_for_log_anywhere "$TMP_DIR" "MCP server initialized on port"
MCP_PORT="$(grep -o 'MCP server initialized on port [0-9]*' "$TMP_DIR/app.log" | tail -1 | grep -o '[0-9]*$')"
if [ -z "$MCP_PORT" ]; then
    log_error "The MCP server's port was not found in the log"
    exit 1
fi
MCP_URL="http://127.0.0.1:$MCP_PORT/mcp"
log_info "MCP server at $MCP_URL"

#
# Posts one JSON-RPC message to the MCP route and prints the reply body as JSON. The reply is JSON or a single server-sent event.
# Usage: mcp_post <json>
#
mcp_post() {
    local body_file="$TMP_DIR/mcp-reply.txt"
    if ! curl -sS --max-time 60 -X POST "$MCP_URL" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        --data "$1" -o "$body_file"; then
        log_error "POST to the MCP server failed"
        exit 1
    fi
    sed -n 's/^data: *//p' "$body_file" | head -1 | grep . || cat "$body_file"
}

log_info "initialize..."
INIT_REPLY="$(mcp_post '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}')"
SERVER_NAME="$(echo "$INIT_REPLY" | jq -r '.result.serverInfo.name')"
if [ "$SERVER_NAME" != "photosphere" ]; then
    log_error "Expected server name photosphere, got: $INIT_REPLY"
    exit 1
fi

log_info "tools/list..."
TOOLS_REPLY="$(mcp_post '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
for tool in list_databases get_database_summary open_database; do
    if ! echo "$TOOLS_REPLY" | jq -e --arg tool "$tool" '.result.tools | map(.name) | index($tool)' > /dev/null; then
        log_error "tools/list lacks $tool: $TOOLS_REPLY"
        exit 1
    fi
done

log_info "tools/call list_databases..."
LIST_REPLY="$(mcp_post '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_databases","arguments":{}}}')"
LIST_TEXT="$(echo "$LIST_REPLY" | jq -r '.result.content[0].text')"
LISTED_NAME="$(echo "$LIST_TEXT" | jq -r '.[0].name')"
LISTED_PATH="$(echo "$LIST_TEXT" | jq -r '.[0].path')"
if [ "$LISTED_NAME" != "McpDatabase" ] || [ "$LISTED_PATH" != "$DATABASE_PATH" ]; then
    log_error "list_databases returned: $LIST_REPLY"
    exit 1
fi

# With nothing open the page answers get_database_summary itself.
log_info "tools/call get_database_summary with no database open..."
NONE_REPLY="$(mcp_post '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_database_summary","arguments":{}}}')"
if [ "$(echo "$NONE_REPLY" | jq -r '.result.content[0].text')" != "No database is currently open in Photosphere." ]; then
    log_error "Unexpected reply with no database open: $NONE_REPLY"
    exit 1
fi

log_info "tools/call open_database..."
OPEN_ARGS="$(jq -cn --arg path "$DATABASE_PATH" '{jsonrpc:"2.0",id:5,method:"tools/call",params:{name:"open_database",arguments:{path:$path}}}')"
OPEN_REPLY="$(mcp_post "$OPEN_ARGS")"
if [ "$(echo "$OPEN_REPLY" | jq -r '.result.content[0].text')" != "Opened database at $DATABASE_PATH" ]; then
    log_error "open_database returned: $OPEN_REPLY"
    exit 1
fi
wait_for_log "$TMP_DIR" "Gallery items rendered"

log_info "tools/call get_database_summary..."
SUMMARY_REPLY="$(mcp_post '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_database_summary","arguments":{}}}')"
SUMMARY_TEXT="$(echo "$SUMMARY_REPLY" | jq -r '.result.content[0].text')"

# The two photos were imported into the database, so the summary reports them as imports and holds them in its tree of files, with a
# full hash.
ORIGINALS="$(ls -1 "$DATABASE_PATH/asset" | wc -l | tr -d ' ')"
IMPORTS="$(echo "$SUMMARY_TEXT" | jq -r '.totalImports')"
FILES="$(echo "$SUMMARY_TEXT" | jq -r '.totalFiles')"
FULL_HASH="$(echo "$SUMMARY_TEXT" | jq -r '.fullHash')"
if [ "$IMPORTS" != "$ORIGINALS" ] || [ "$FILES" -lt "$ORIGINALS" ] || ! [[ "$FULL_HASH" =~ ^[0-9a-f]{64}$ ]]; then
    log_error "get_database_summary returned: $SUMMARY_REPLY"
    exit 1
fi

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 60 passed: mcp-server"
