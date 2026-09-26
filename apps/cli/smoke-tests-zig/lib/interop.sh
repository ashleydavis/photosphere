#!/bin/bash

# Helpers for the TypeScript/Zig interop smoke tests.
# Sourced by each test after smoke-tests/lib/common.sh, whose helpers (invoke_command, expect_*, ...) the tests also use.

# Absolute path to the Zig port of the CLI (apps/cli-zig).
ZIG_CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../cli-zig" && pwd)"

# Get the TypeScript CLI command.
get_ts_cli_command() {
    get_cli_command
}

# Get the Zig CLI command.
get_zig_cli_command() {
    if [[ "$OSTYPE" == "msys"* ]] || [[ "$OSTYPE" == "cygwin"* ]]; then
        echo "$ZIG_CLI_DIR/zig-out/bin/psi.exe"
    else
        echo "$ZIG_CLI_DIR/zig-out/bin/psi"
    fi
}

# Path of the deterministic test UUID counter file (NODE_ENV=testing).
get_uuid_counter_file() {
    echo "$TEST_TMP_DIR/photosphere-test-uuid-counter"
}

# Saves the test UUID counter so two replications can be run from the same UUID sequence.
save_uuid_counter() {
    local backup_file="$1"
    cp "$(get_uuid_counter_file)" "$backup_file"
}

# Restores the test UUID counter saved by save_uuid_counter.
restore_uuid_counter() {
    local backup_file="$1"
    cp "$backup_file" "$(get_uuid_counter_file)"
}

# Asserts that a replica made by the Zig CLI matches a replica of the same source made by the TypeScript CLI:
# identical files, and identical merkle trees apart from file modification times.
expect_replicas_match() {
    local ts_replica_dir="$1"
    local zig_replica_dir="$2"
    local compare_output
    invoke_command "Compare TypeScript and Zig replicas" "bun run smoke-tests-zig/lib/compare-replicas.ts $ts_replica_dir $zig_replica_dir" 0 "compare_output"
    expect_output_string "$compare_output" "Replicas match" "Zig replica matches the TypeScript replica"
}

# Asserts that the numeric verify results printed by two verify runs are identical.
expect_same_verify_counts() {
    local first_output="$1"
    local second_output="$2"
    local label
    for label in "Files imported:" "Total files:" "Files processed:" "Nodes processed:" "Unmodified:" "Modified:" "New:" "Removed:" "Failures:" "Record mismatches:"; do
        expect_value "$(parse_numeric "$second_output" "$label")" "$(parse_numeric "$first_output" "$label")" "Zig and TypeScript verify agree on $label"
    done
    expect_value "$(echo "$second_output" | grep -m1 "Total size:" | sed 's/.*Total size: *//')" "$(echo "$first_output" | grep -m1 "Total size:" | sed 's/.*Total size: *//')" "Zig and TypeScript verify agree on total size"
}

# Asserts that every asset file in a database starts with the PSEN encryption header.
expect_assets_encrypted() {
    local db_dir="$1"
    local asset_file
    local asset_count=0
    for asset_file in "$db_dir"/asset/*; do
        if [ "$(head -c 4 "$asset_file")" != "PSEN" ]; then
            log_error "Asset is not encrypted: $asset_file"
            exit 1
        fi
        asset_count=$((asset_count + 1))
    done
    expect_value "$([ "$asset_count" -gt 0 ] && echo yes || echo no)" "yes" "Database has encrypted assets"
}
