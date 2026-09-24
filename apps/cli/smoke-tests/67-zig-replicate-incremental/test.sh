#!/bin/bash
DESCRIPTION="Zig CLI replicates TypeScript changes into an existing replica"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/functions.sh"
trap cleanup_and_show_summary EXIT

test_zig_replicate_incremental() {
    local test_number="$1"
    print_test_header "$test_number" "ZIG INCREMENTAL REPLICATION OF TYPESCRIPT CHANGES"

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

    # First replication with both CLIs.
    save_uuid_counter "$uuid_counter_backup"
    invoke_command "First replication with TypeScript" "$ts_cli replicate --db $source_dir --dest $ts_replica_dir --yes --force"
    restore_uuid_counter "$uuid_counter_backup"
    invoke_command "First replication with Zig" "$zig_cli replicate --db $source_dir --dest $zig_replica_dir --yes --force"
    expect_replicas_match "$ts_replica_dir" "$zig_replica_dir"

    # Replicating again with no changes copies nothing.
    local unchanged_output
    invoke_command "Replicate unchanged database with Zig" "$zig_cli replicate --db $source_dir --dest $zig_replica_dir --yes --force" 0 "unchanged_output"
    expect_output_value "$unchanged_output" "Total files copied:" "0" "Zig copies nothing when nothing changed"

    # Change the source with the TypeScript CLI.
    invoke_command "Add MP4 file with TypeScript" "$ts_cli add --db $source_dir $TEST_FILES_DIR/multiple-files/test.mp4 --yes"
    invoke_command "Add WebP file with TypeScript" "$ts_cli add --db $source_dir $TEST_FILES_DIR/test.webp --yes"
    local asset_id=$(ls "$source_dir/asset" | sort | head -1)
    invoke_command "Remove an asset with TypeScript" "$ts_cli remove --db $source_dir $asset_id --yes"

    # Replicate the changes with both CLIs into their existing replicas.
    save_uuid_counter "$uuid_counter_backup"
    local ts_replicate_output
    invoke_command "Replicate changes with TypeScript" "$ts_cli replicate --db $source_dir --dest $ts_replica_dir --yes --force" 0 "ts_replicate_output"
    restore_uuid_counter "$uuid_counter_backup"
    local zig_replicate_output
    invoke_command "Replicate changes with Zig" "$zig_cli replicate --db $source_dir --dest $zig_replica_dir --yes --force" 0 "zig_replicate_output"
    expect_output_value "$zig_replicate_output" "Total files copied:" "$(parse_numeric "$ts_replicate_output" "Total files copied:")" "Zig and TypeScript agree on files copied"
    expect_output_value "$zig_replicate_output" "Total records copied:" "$(parse_numeric "$ts_replicate_output" "Total records copied:")" "Zig and TypeScript agree on records copied"
    expect_replicas_match "$ts_replica_dir" "$zig_replica_dir"

    # The TypeScript CLI must accept the updated Zig replica.
    local ts_verify_output
    invoke_command "Verify Zig replica with TypeScript" "$ts_cli verify --db $zig_replica_dir --yes" 0 "ts_verify_output"
    expect_output_string "$ts_verify_output" "Database verification passed - all files are intact" "TypeScript verify passes on the updated Zig replica"
    local compare_output
    invoke_command "Compare source and Zig replica with TypeScript" "$ts_cli compare --db $source_dir --dest $zig_replica_dir --yes" 0 "compare_output"
    expect_output_string "$compare_output" "No differences detected" "TypeScript compare finds no differences"

    test_passed
}

test_zig_replicate_incremental "${1:-67}"
