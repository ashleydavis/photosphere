#!/bin/bash
DESCRIPTION="Database config tracks lastModifiedAt and lastSyncedAt across add/sync/repair"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

#
# Read a top-level string field from a database config.json.
# Echoes the field value or an empty string if the field or file is missing.
#
read_config_field() {
    local config_path="$1"
    local field_name="$2"

    if [ ! -f "$config_path" ]; then
        echo ""
        return 0
    fi

    bun -e "
        const fs = require('node:fs');
        const data = JSON.parse(fs.readFileSync('$config_path', 'utf8'));
        process.stdout.write(typeof data['$field_name'] === 'string' ? data['$field_name'] : '');
    "
}

#
# Asserts that a string is a valid ISO 8601 date-time.
#
expect_valid_iso_date() {
    local value="$1"
    local description="$2"

    bun -e "
        const value = '$value';
        const parsed = Date.parse(value);
        if (!value || Number.isNaN(parsed)) {
            console.error('expected valid ISO date, got: ' + JSON.stringify(value));
            process.exit(1);
        }
    "
    if [ $? -eq 0 ]; then
        log_success "$description: $value"
    else
        log_error "$description: $value is not a valid ISO date"
        exit 1
    fi
}

test_config_timestamps() {
    local test_number="$1"
    print_test_header "$test_number" "DATABASE CONFIG TIMESTAMPS"

    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"

    # ── 1. add bumps lastModifiedAt ──────────────────────────────────────────
    local db_dir="$test_dir/db-add"
    rm -rf "$db_dir"
    invoke_command "Initialize database" "$(get_cli_command) init --db $db_dir --yes"

    local config_path="$db_dir/.db/config.json"
    check_exists "$config_path" "Initial config file"
    local before_modified=$(read_config_field "$config_path" "lastModifiedAt")
    if [ -n "$before_modified" ]; then
        log_error "Fresh database should not have lastModifiedAt set, got: $before_modified"
        exit 1
    fi
    log_success "Fresh database has no lastModifiedAt"

    invoke_command "Add PNG file" "$(get_cli_command) add --db $db_dir $TEST_FILES_DIR/test.png --yes"

    local after_add_modified=$(read_config_field "$config_path" "lastModifiedAt")
    expect_valid_iso_date "$after_add_modified" "lastModifiedAt set after add"

    # ── 2. sync stamps both sides with the same lastSyncedAt ─────────────────
    local source_dir="$test_dir/db-sync-source"
    local replica_dir="$test_dir/db-sync-replica"
    rm -rf "$source_dir" "$replica_dir"

    invoke_command "Initialize sync source database" "$(get_cli_command) init --db $source_dir --yes"
    invoke_command "Add file to sync source" "$(get_cli_command) add --db $source_dir $TEST_FILES_DIR/test.jpg --yes"
    invoke_command "Replicate to create sync target" "$(get_cli_command) replicate --db $source_dir --dest $replica_dir --yes --force"

    invoke_command "Sync source and replica" "$(get_cli_command) sync --db $source_dir --dest $replica_dir --yes"

    local source_synced=$(read_config_field "$source_dir/.db/config.json" "lastSyncedAt")
    local replica_synced=$(read_config_field "$replica_dir/.db/config.json" "lastSyncedAt")

    expect_valid_iso_date "$source_synced" "Source database lastSyncedAt"
    expect_valid_iso_date "$replica_synced" "Replica database lastSyncedAt"
    expect_value "$source_synced" "$replica_synced" "Source and replica lastSyncedAt match"

    # ── 3. repair bumps lastModifiedAt when records need repair ──────────────
    local repair_db_dir="$test_dir/db-repair"
    local repair_source_dir="$test_dir/db-repair-source"
    rm -rf "$repair_db_dir" "$repair_source_dir"

    invoke_command "Initialize repair source database" "$(get_cli_command) init --db $repair_source_dir --yes"
    invoke_command "Add file to repair source" "$(get_cli_command) add --db $repair_source_dir $TEST_FILES_DIR/test.png --yes"
    invoke_command "Replicate to create repair target" "$(get_cli_command) replicate --db $repair_source_dir --dest $repair_db_dir --yes --force"

    # Capture pre-repair lastModifiedAt (from the replicate process the target may have its own value).
    local before_repair_modified=$(read_config_field "$repair_db_dir/.db/config.json" "lastModifiedAt")

    # Damage the target by deleting an asset file so repair has work to do.
    local file_to_delete=$(find "$repair_db_dir/asset" -type f | head -1)
    if [ -z "$file_to_delete" ]; then
        log_error "No asset file found in repair target to delete"
        exit 1
    fi
    rm "$file_to_delete"
    log_info "Deleted asset file to simulate damage: ${file_to_delete#$repair_db_dir/}"

    # Sleep briefly so the post-repair timestamp is strictly later than pre.
    sleep 1

    invoke_command "Repair damaged database" "$(get_cli_command) repair --db $repair_db_dir --source $repair_source_dir --yes" 0

    local after_repair_modified=$(read_config_field "$repair_db_dir/.db/config.json" "lastModifiedAt")
    expect_valid_iso_date "$after_repair_modified" "lastModifiedAt set after repair"

    if [ -n "$before_repair_modified" ]; then
        if [[ "$after_repair_modified" > "$before_repair_modified" ]]; then
            log_success "Repair advanced lastModifiedAt past pre-repair value"
        else
            log_error "Repair did not advance lastModifiedAt: before=$before_repair_modified after=$after_repair_modified"
            exit 1
        fi
    fi

    rm -rf "$test_dir"
    test_passed
}

test_config_timestamps "${1:-64}"
