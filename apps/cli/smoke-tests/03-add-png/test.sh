#!/bin/bash
DESCRIPTION="Add PNG file to database"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/functions.sh"
trap cleanup_and_show_summary EXIT

TEST_DB_DIR="$(get_test_dir 3)/test-db"
invoke_command "Initialize database" "$(get_cli_command) init --db $TEST_DB_DIR --yes"

test_add_png_file 3
