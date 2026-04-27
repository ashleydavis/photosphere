#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/functions.sh"
trap cleanup_and_show_summary EXIT

TEST_DB_DIR="$(get_test_dir 23)/test-db"
invoke_command "Initialize database (setup)" "$(get_cli_command) init --db $TEST_DB_DIR --yes"

test_cannot_create_over_existing 23
