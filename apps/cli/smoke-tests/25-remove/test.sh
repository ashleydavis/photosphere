#!/bin/bash
DESCRIPTION="Remove asset by ID from database"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/functions.sh"
trap cleanup_and_show_summary EXIT

TEST_DB_DIR="$(get_test_dir 25)/test-db"
invoke_command "Initialize database" "$(get_cli_command) init --db $TEST_DB_DIR --yes"
populate_db_with_5_files "$TEST_DB_DIR"

test_remove_asset 25
