#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/functions.sh"
trap cleanup_and_show_summary EXIT

TEST_DB_DIR="$(get_test_dir 6)/test-db"
invoke_command "Initialize database" "$(get_cli_command) init --db $TEST_DB_DIR --yes"
invoke_command "Add PNG (setup)" "$(get_cli_command) add --db $TEST_DB_DIR $TEST_FILES_DIR/test.png --yes"

test_add_same_file 6
