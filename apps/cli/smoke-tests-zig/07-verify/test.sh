#!/bin/bash
DESCRIPTION="Zig replicate/verify: Verify database integrity"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../smoke-tests/lib/common.sh"
source "$SCRIPT_DIR/../lib/interop.sh"
source "$SCRIPT_DIR/../lib/zig-functions.sh"
trap cleanup_and_show_summary EXIT

TEST_DB_DIR="$(get_test_dir 07)/test-db"
create_db_with_5_files "$TEST_DB_DIR"

test_database_verify 13
