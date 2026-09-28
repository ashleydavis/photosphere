#!/bin/bash
DESCRIPTION="psi mcp serves an MCP client over stdio: it lists its tools, opens a database, reads, saves, verifies and imports media files, and the TypeScript CLI verifies what it imported"

# An MCP client talks to `psi mcp` with newline-delimited JSON-RPC messages on its stdin and reads
# the answers, one line each, from its stdout. Each session here is a file of messages fed to the
# Zig CLI; it answers them in order and exits when its stdin ends. The messages are built with jq,
# so that paths are escaped the way JSON needs (a Windows path has backslashes), and the answers are
# read with jq too. Asset IDs are not known until the database has been listed, so the database is
# listed in a first session and used in a second one.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

#
# Prints a tools/call request with an id, a tool name and the JSON of the arguments.
#
tool_call() {
    local id="$1"
    local tool_name="$2"
    local arguments="$3"

    jq -cn --argjson id "$id" --arg name "$tool_name" --argjson arguments "$arguments" \
        '{ jsonrpc: "2.0", id: $id, method: "tools/call", params: { name: $name, arguments: $arguments } }'
}

#
# Prints the answer with an id from a session's output.
#
answer() {
    local output_file="$1"
    local id="$2"

    tr -d '\r' < "$output_file" | jq -c --argjson id "$id" 'select(.id == $id)'
}

#
# Prints the text of the tool result with an id from a session's output.
#
tool_text() {
    local output_file="$1"
    local id="$2"

    answer "$output_file" "$id" | jq -r '.result.content[0].text' | tr -d '\r'
}

#
# Fails when the tool result with an id is an error.
#
expect_tool_success() {
    local output_file="$1"
    local id="$2"
    local description="$3"

    local is_error
    is_error="$(answer "$output_file" "$id" | jq -r '.result.isError // false' | tr -d '\r')"
    expect_value "$is_error" "false" "$description"
}

test_mcp() {
    local test_number="$1"
    print_test_header "$test_number" "MCP SERVER"

    local test_dir
    test_dir="$(get_test_dir "$test_number")"
    local db_path="$test_dir/db"
    local save_dir="$test_dir/saved"
    mkdir -p "$test_dir"

    invoke_command "Create a database" "$(get_zig_cli_command) init --db \"$db_path\" --yes"
    ts_verify "$db_path"
    invoke_command "Add a PNG and a JPG" "$(get_zig_cli_command) add --db \"$db_path\" --yes \"$TEST_FILES_DIR/test.png\" \"$TEST_FILES_DIR/test.jpg\""
    ts_verify "$db_path"

    # --- 1. Handshake, tools and listing. ---

    local first_input="$test_dir/first-session.jsonl"
    local first_output="$test_dir/first-session-output.jsonl"
    local first_errors="$test_dir/first-session-errors.txt"
    {
        echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1.0.0"}}}'
        echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
        echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
        echo '{"jsonrpc":"2.0","id":3,"method":"ping"}'
        tool_call 4 list_media_files '{}'
        tool_call 5 open_database "$(jq -cn --arg path "$db_path" '{ path: $path }')"
        tool_call 6 list_media_files '{"limit":10}'
        tool_call 7 get_database_summary '{}'
    } > "$first_input"

    invoke_command "Run an MCP session with the Zig CLI" "$(get_zig_cli_command) -q mcp --yes < \"$first_input\" > \"$first_output\" 2> \"$first_errors\""

    expect_value "$(tr -d '\r' < "$first_errors")" "Photosphere MCP server running" "The server says on stderr that it is running"
    expect_value "$(tr -d '\r' < "$first_output" | wc -l | tr -d ' ')" "7" "Every request got an answer, and the notification none"
    expect_value "$(answer "$first_output" 1 | jq -r '.result.serverInfo.name + " " + .result.protocolVersion' | tr -d '\r')" "photosphere 2025-06-18" "initialize reports the server and agrees on the protocol version"
    expect_value "$(answer "$first_output" 2 | jq -r '[.result.tools[].name] | join(",")' | tr -d '\r')" \
        "list_databases,open_database,close_database,get_database_summary,list_media_files,get_media_file_info,search_media_files,save_media_file,import_media_files,verify_database" \
        "tools/list reports the ten tools"
    expect_value "$(answer "$first_output" 2 | jq -r '.result.tools[] | select(.name == "save_media_file") | .inputSchema.properties.type.enum | join(",")' | tr -d '\r')" "original,display,thumb" "tools/list reports the input schema of a tool"
    expect_value "$(answer "$first_output" 3 | jq -c '.result' | tr -d '\r')" "{}" "ping answers"
    expect_value "$(tool_text "$first_output" 4)" "No database is currently open. Use list_databases / open_database first." "A tool needs an open database"
    expect_value "$(tool_text "$first_output" 5)" "Opened database at $db_path" "open_database opens the database"
    expect_value "$(tool_text "$first_output" 6 | jq -r '[.mediaFiles[].origFileName] | sort | join(",")' | tr -d '\r')" "test.jpg,test.png" "list_media_files lists both media files"
    expect_value "$(tool_text "$first_output" 7 | jq -r '.totalImports' | tr -d '\r')" "2" "get_database_summary counts both imports"

    local png_id
    png_id="$(tool_text "$first_output" 6 | jq -r '.mediaFiles[] | select(.origFileName == "test.png") | ._id' | tr -d '\r')"
    log_info "The ID of test.png: $png_id"

    # --- 2. Reading, saving, verifying and importing. ---

    local second_input="$test_dir/second-session.jsonl"
    local second_output="$test_dir/second-session-output.jsonl"
    {
        tool_call 1 open_database "$(jq -cn --arg path "$db_path" '{ path: $path }')"
        tool_call 2 get_media_file_info "$(jq -cn --arg id "$png_id" '{ assetId: $id }')"
        tool_call 3 search_media_files '{"query":"PNG"}'
        tool_call 4 save_media_file "$(jq -cn --arg id "$png_id" --arg path "$save_dir/original.png" '{ assetId: $id, outputPath: $path }')"
        tool_call 5 verify_database '{}'
        tool_call 6 import_media_files "$(jq -cn --arg path "$TEST_FILES_DIR/test.webp" '{ paths: [ $path ] }')"
        tool_call 7 no_such_tool '{}'
        tool_call 8 list_media_files '{"limit":0}'
        tool_call 9 close_database '{}'
    } > "$second_input"

    invoke_command "Run a second MCP session with the Zig CLI" "$(get_zig_cli_command) -q mcp --yes < \"$second_input\" > \"$second_output\" 2> /dev/null"

    expect_value "$(tool_text "$second_output" 2 | jq -r '._id + " " + .contentType' | tr -d '\r')" "$png_id image/png" "get_media_file_info returns the record of the media file"
    expect_value "$(tool_text "$second_output" 3 | jq -r '[.[].origFileName] | join(",")' | tr -d '\r')" "test.png" "search_media_files finds the PNG by name, ignoring case"
    expect_tool_success "$second_output" 4 "save_media_file succeeds"
    check_exists "$save_dir/original.png" "The saved original"
    if ! cmp -s "$TEST_FILES_DIR/test.png" "$save_dir/original.png"; then
        log_error "The saved original is not the file that was added"
        exit 1
    fi
    log_success "The saved original is the file that was added"
    expect_value "$(tool_text "$second_output" 4)" "Wrote $(wc -c < "$TEST_FILES_DIR/test.png" | tr -d ' ') bytes to $save_dir/original.png" "save_media_file reports what it wrote"
    expect_value "$(tool_text "$second_output" 5 | jq -r '"\(.assets.numFailures) \(.assets.modified | length) \(.databaseFiles.invalidFiles | length)"' | tr -d '\r')" "0 0 0" "verify_database finds no problems"
    expect_value "$(tool_text "$second_output" 6 | jq -r '.filesAdded' | tr -d '\r')" "1" "import_media_files imports the WEBP"
    expect_value "$(tool_text "$second_output" 7)" "MCP error -32602: Tool no_such_tool not found" "An unknown tool is an error result"
    expect_value "$(answer "$second_output" 7 | jq -r '.result.isError' | tr -d '\r')" "true" "An unknown tool's result is marked as an error"
    expect_value "$(answer "$second_output" 8 | jq -r '.result.isError' | tr -d '\r')" "true" "Invalid arguments are an error result"
    expect_value "$(tool_text "$second_output" 9)" "Closed database at $db_path" "close_database closes the database"

    # --- 3. What the Zig CLI imported through MCP is a sound database for the TypeScript CLI. ---

    local summary_output
    invoke_command "Summarize the database with the Zig CLI" "$(get_zig_cli_command) summary --db \"$db_path\" --yes" 0 "summary_output"
    expect_value "$(parse_numeric "$summary_output" "Files imported:")" "3" "The database holds the three imports"
    ts_verify "$db_path"

    test_passed
}

test_mcp "${1:-101}"
