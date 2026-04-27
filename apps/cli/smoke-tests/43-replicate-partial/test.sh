#!/bin/bash
DESCRIPTION="Test partial replication (README and .db files only, no media)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_replicate_partial() {
    local test_number="$1"
    print_test_header "$test_number" "PARTIAL REPLICATION (README AND DB FILES ONLY)"

    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"
    local source_db_dir="$test_dir/source-db"
    local replica_dir="$test_dir/partial-replica"

    local v6_db_dir="../../test/dbs/v6"
    log_info "Copying v6 fixture database to isolated temp directory: $source_db_dir"
    cp -r "$v6_db_dir" "$source_db_dir"

    log_info "Source database path: $source_db_dir"
    log_info "Partial replica database path: $replica_dir"

    # Run partial replicate command
    local replicate_output
    invoke_command "Partial replicate database" "$(get_cli_command) replicate --db $source_db_dir --dest $replica_dir --partial --yes --force" 0 "replicate_output"

    # Check if replication was successful
    expect_output_string "$replicate_output" "Replication completed successfully" "Partial replication completed successfully"

    # Check that the core metadata files were copied
    check_exists "$replica_dir" "Partial replica database directory"
    check_exists "$replica_dir/.db" "Partial replica metadata directory"
    check_exists "$replica_dir/.db/files.dat" "Partial replica files merkle tree"
    check_exists "$replica_dir/.db/config.json" "Partial replica config file"
    check_exists "$replica_dir/README.md" "Partial replica README"

    # No asset, display, or thumb files should be present
    local replica_thumb_count=0
    local replica_asset_count=0
    local replica_display_count=0

    if [ -d "$replica_dir/thumb" ]; then
        replica_thumb_count=$(find "$replica_dir/thumb" -type f | wc -l)
    fi
    if [ -d "$replica_dir/asset" ]; then
        replica_asset_count=$(find "$replica_dir/asset" -type f | wc -l)
    fi
    if [ -d "$replica_dir/display" ]; then
        replica_display_count=$(find "$replica_dir/display" -type f | wc -l)
    fi

    log_info "Partial replica media file counts (all should be 0):"
    log_info "  Thumb files: $replica_thumb_count"
    log_info "  Asset files: $replica_asset_count"
    log_info "  Display files: $replica_display_count"

    expect_value "$replica_thumb_count" "0" "No thumb files should be copied in partial mode"
    expect_value "$replica_asset_count" "0" "No asset files should be copied in partial mode"
    expect_value "$replica_display_count" "0" "No display files should be copied in partial mode"

    # BSON records (asset metadata) should have been replicated
    local source_summary
    local replica_summary
    invoke_command "Get source database summary" "$(get_cli_command) summary --db $source_db_dir --yes" 0 "source_summary"
    invoke_command "Get partial replica summary" "$(get_cli_command) summary --db $replica_dir --yes" 0 "replica_summary"

    local source_files_imported=$(parse_numeric "$source_summary" "Files imported:")
    local replica_files_imported=$(parse_numeric "$replica_summary" "Files imported:")
    expect_value "$replica_files_imported" "$source_files_imported" "Partial replica files-imported count matches source"

    # Database IDs must match
    log_info "Verifying database IDs match for original and partial replica"
    local source_id_output
    local replica_id_output
    invoke_command "Get source database ID" "$(get_cli_command) database-id --db $source_db_dir --yes" 0 "source_id_output"
    invoke_command "Get partial replica database ID" "$(get_cli_command) database-id --db $replica_dir --yes" 0 "replica_id_output"

    local source_id=$(echo "$source_id_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    local replica_id=$(echo "$replica_id_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)

    if [ "$source_id" = "$replica_id" ]; then
        log_success "Database IDs match: $source_id"
    else
        log_error "Database IDs do not match"
        log_error "Source ID: $source_id"
        log_error "Partial replica ID: $replica_id"
        exit 1
    fi

    # Verify passes for a partial database - missing media files are expected and ignored
    log_info "Verifying partial replica database - missing media files should be ignored"
    local verify_output
    invoke_command "Verify partial replica database" "$(get_cli_command) verify --db $replica_dir --yes" 0 "verify_output"
    expect_output_string "$verify_output" "Database verification passed - all files are intact" "Partial database verification should pass despite missing media files"

    # Compare source and partial replica - merkle trees should match (isPartial is metadata, not a leaf)
    local compare_output
    invoke_command "Compare source and partial replica" "$(get_cli_command) compare --db $source_db_dir --dest $replica_dir --yes" 0 "compare_output"
    expect_output_string "$compare_output" "No differences detected" "Source and partial replica have no merkle tree differences"

    rm -rf "$test_dir"
    test_passed
}

test_replicate_partial "${1:-43}"
