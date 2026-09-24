#!/bin/bash
DESCRIPTION="Zig CLI replicates a TypeScript database and TypeScript verifies the replica"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/functions.sh"
trap cleanup_and_show_summary EXIT

test_zig_replicate_ts_db() {
    local test_number="$1"
    print_test_header "$test_number" "ZIG REPLICATION OF A TYPESCRIPT DATABASE"

    local test_dir=$(get_test_dir "$test_number")
    local source_dir="$test_dir/ts-db"
    local ts_replica_dir="$test_dir/ts-replica"
    local zig_replica_dir="$test_dir/zig-replica"
    local uuid_counter_backup="$test_dir/uuid-counter-backup"
    local ts_cli="$(get_ts_cli_command)"
    local zig_cli="$(get_zig_cli_command)"

    check_exists "$zig_cli" "Zig CLI binary"

    # Create and populate the source database with the TypeScript CLI.
    invoke_command "Initialize database with TypeScript" "$ts_cli init --db $source_dir --yes"
    invoke_command "Add PNG file with TypeScript" "$ts_cli add --db $source_dir $TEST_FILES_DIR/test.png --yes"
    invoke_command "Add JPG file with TypeScript" "$ts_cli add --db $source_dir $TEST_FILES_DIR/test.jpg --yes"
    invoke_command "Add MP4 file with TypeScript" "$ts_cli add --db $source_dir $TEST_FILES_DIR/multiple-files/test.mp4 --yes"
    invoke_command "Add multiple images with TypeScript" "$ts_cli add --db $source_dir $MULTIPLE_IMAGES_DIR/ --yes"

    # Replicate with both CLIs from the same deterministic UUID sequence.
    save_uuid_counter "$uuid_counter_backup"
    local ts_replicate_output
    invoke_command "Replicate with TypeScript" "$ts_cli replicate --db $source_dir --dest $ts_replica_dir --yes --force" 0 "ts_replicate_output"
    restore_uuid_counter "$uuid_counter_backup"
    local zig_replicate_output
    invoke_command "Replicate with Zig" "$zig_cli replicate --db $source_dir --dest $zig_replica_dir --yes --force" 0 "zig_replicate_output"
    expect_output_string "$zig_replicate_output" "Replication completed successfully" "Zig replication completed successfully"
    expect_output_value "$zig_replicate_output" "Total files imported:" "$(parse_numeric "$ts_replicate_output" "Total files imported:")" "Zig and TypeScript agree on files imported"
    expect_output_value "$zig_replicate_output" "Total files copied:" "$(parse_numeric "$ts_replicate_output" "Total files copied:")" "Zig and TypeScript agree on files copied"
    expect_output_value "$zig_replicate_output" "Total records copied:" "$(parse_numeric "$ts_replicate_output" "Total records copied:")" "Zig and TypeScript agree on records copied"

    # The Zig replica must be identical to the TypeScript replica.
    expect_replicas_match "$ts_replica_dir" "$zig_replica_dir"

    # The TypeScript CLI must accept the Zig replica.
    local ts_verify_output
    invoke_command "Verify Zig replica with TypeScript" "$ts_cli verify --db $zig_replica_dir --yes" 0 "ts_verify_output"
    expect_output_string "$ts_verify_output" "Database verification passed - all files are intact" "TypeScript verify passes on the Zig replica"
    local ts_full_verify_output
    invoke_command "Full verify of Zig replica with TypeScript" "$ts_cli verify --db $zig_replica_dir --full --yes" 0 "ts_full_verify_output"
    expect_output_string "$ts_full_verify_output" "Database verification passed - all files are intact" "TypeScript full verify passes on the Zig replica"

    local source_hash_output
    local replica_hash_output
    invoke_command "Source root hash with TypeScript" "$ts_cli root-hash --db $source_dir --yes" 0 "source_hash_output"
    invoke_command "Zig replica root hash with TypeScript" "$ts_cli root-hash --db $zig_replica_dir --yes" 0 "replica_hash_output"
    expect_value "$(echo "$replica_hash_output" | tail -1 | xargs)" "$(echo "$source_hash_output" | tail -1 | xargs)" "Zig replica root hash matches the source"

    local source_id_output
    local replica_id_output
    invoke_command "Source database ID with TypeScript" "$ts_cli database-id --db $source_dir --yes" 0 "source_id_output"
    invoke_command "Zig replica database ID with TypeScript" "$ts_cli database-id --db $zig_replica_dir --yes" 0 "replica_id_output"
    expect_value "$(echo "$replica_id_output" | tail -1 | xargs)" "$(echo "$source_id_output" | tail -1 | xargs)" "Zig replica database ID matches the source"

    local compare_output
    invoke_command "Compare source and Zig replica with TypeScript" "$ts_cli compare --db $source_dir --dest $zig_replica_dir --yes" 0 "compare_output"
    expect_output_string "$compare_output" "No differences detected" "TypeScript compare finds no differences"

    # The Zig CLI must also accept its own replica.
    local zig_verify_output
    invoke_command "Verify Zig replica with Zig" "$zig_cli verify --db $zig_replica_dir --yes" 0 "zig_verify_output"
    expect_same_verify_counts "$ts_verify_output" "$zig_verify_output"

    test_passed
}

test_zig_replicate_ts_db "${1:-66}"
