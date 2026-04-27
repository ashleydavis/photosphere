#!/bin/bash
DESCRIPTION="Add same multiple files again"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/functions.sh"
trap cleanup_and_show_summary EXIT

TEST_DB_DIR="$(get_test_dir 8)/test-db"
invoke_command "Initialize database" "$(get_cli_command) init --db $TEST_DB_DIR --yes"
if [ -d "$MULTIPLE_IMAGES_DIR" ]; then
    invoke_command "Add multiple images (setup)" "$(get_cli_command) add --db $TEST_DB_DIR $MULTIPLE_IMAGES_DIR/ --yes"
fi

test_add_same_multiple_files 8
