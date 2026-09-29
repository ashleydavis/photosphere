#!/bin/bash
DESCRIPTION="Add same file again (no duplication)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/functions.sh"
trap cleanup_and_show_summary EXIT

TEST_DB_DIR="$(get_test_dir 6)/test-db"
invoke_command "Initialize database" "$(get_zig_cli_command) init --db $TEST_DB_DIR --yes"
ts_verify "$TEST_DB_DIR"
invoke_command "Add PNG (setup)" "$(get_zig_cli_command) add --db $TEST_DB_DIR $TEST_FILES_DIR/test.png --yes"
ts_verify "$TEST_DB_DIR"

test_add_same_file 6
