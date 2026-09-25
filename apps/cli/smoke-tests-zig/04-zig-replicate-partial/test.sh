#!/bin/bash
DESCRIPTION="Zig CLI partially replicates a TypeScript database and TypeScript verifies the replica"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../smoke-tests/lib/common.sh"
source "$SCRIPT_DIR/../lib/interop.sh"

trap cleanup_and_show_summary EXIT

test_zig_replicate_partial() {
    local test_number="$1"
    print_test_header "$test_number" "ZIG PARTIAL REPLICATION OF A TYPESCRIPT DATABASE"

    local test_dir=$(get_test_dir "$test_number")
    local source_dir="$test_dir/ts-db"
    local ts_replica_dir="$test_dir/ts-partial-replica"
    local zig_replica_dir="$test_dir/zig-partial-replica"
    local uuid_counter_backup="$test_dir/uuid-counter-backup"
    local ts_cli="$(get_ts_cli_command)"
    local zig_cli="$(get_zig_cli_command)"

    check_exists "$zig_cli" "Zig CLI binary"

    # Create and populate the source database with the TypeScript CLI.
    invoke_command "Initialize database with TypeScript" "$ts_cli init --db $source_dir --yes"
    invoke_command "Add PNG file with TypeScript" "$ts_cli add --db $source_dir $TEST_FILES_DIR/test.png --yes"
    invoke_command "Add multiple images with TypeScript" "$ts_cli add --db $source_dir $MULTIPLE_IMAGES_DIR/ --yes"

    # Partially replicate with both CLIs.
    save_uuid_counter "$uuid_counter_backup"
    invoke_command "Partial replication with TypeScript" "$ts_cli replicate --db $source_dir --dest $ts_replica_dir --partial --yes --force"
    restore_uuid_counter "$uuid_counter_backup"
    local zig_replicate_output
    invoke_command "Partial replication with Zig" "$zig_cli replicate --db $source_dir --dest $zig_replica_dir --partial --yes --force" 0 "zig_replicate_output"
    expect_output_string "$zig_replicate_output" "Replication completed successfully" "Zig partial replication completed successfully"
    expect_replicas_match "$ts_replica_dir" "$zig_replica_dir"

    # The TypeScript CLI must accept the Zig partial replica.
    local ts_verify_output
    invoke_command "Verify Zig partial replica with TypeScript" "$ts_cli verify --db $zig_replica_dir --yes" 0 "ts_verify_output"
    expect_output_string "$ts_verify_output" "Database verification passed - all files are intact" "TypeScript verify passes on the Zig partial replica"

    # Both CLIs verify the partial replica the same way.
    local zig_verify_output
    invoke_command "Verify Zig partial replica with Zig" "$zig_cli verify --db $zig_replica_dir --yes" 0 "zig_verify_output"
    expect_same_verify_counts "$ts_verify_output" "$zig_verify_output"

    test_passed
}

test_zig_replicate_partial "${1:-04}"
