#!/bin/bash
DESCRIPTION="Database state tracks lastModifiedAt and lastSyncedAt across add/sync/repair and syncs early-out when identical"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

#
# Decodes the 32-bit little-endian length prefix that starts at byte offset $2 of the file $1.
# One decimal number per byte, combined by hand, so this does not depend on od's --endian flag,
# which is GNU-only and absent from the od macOS ships.
#
read_state_length() {
    local length_bytes
    length_bytes=($(od -An -v -tu1 -j "$2" -N 4 "$1"))
    echo $(( length_bytes[0] + length_bytes[1] * 256 + length_bytes[2] * 65536 + length_bytes[3] * 16777216 ))
}

#
# Reads a string field from a database's binary state file (.db/state.dat).
# The file layout is [version 4][type 4 "DBST"][payload][checksum 32]; the payload is a
# length-prefixed content-hash buffer followed by three length-prefixed UTF-8 strings
# (lastModifiedAt, lastSyncedAt, lastReplicatedAt). Echoes the field value or an empty string
# if the field or file is missing.
#
read_state_field() {
    local db_dir="$1"
    local field_name="$2"
    local state_file="$db_dir/.db/state.dat"

    if [ ! -f "$state_file" ]; then
        return 0
    fi

    # Shorter than a header plus an empty payload plus a checksum, so it cannot be a state record.
    local state_size
    state_size=$(wc -c < "$state_file")
    if [ "$(( state_size ))" -lt 40 ]; then
        return 0
    fi

    # The "DBST" type marker at offset 4 identifies a state file. Nulls are stripped so a file that
    # is not one cannot put a null byte into the comparison.
    local type_marker
    type_marker=$(tail -c +5 "$state_file" | head -c 4 | LC_ALL=C tr -d '\0')
    if [ "$type_marker" != "DBST" ]; then
        return 0
    fi

    # Skip the length-prefixed content hash, which is raw bytes rather than text, to reach the timestamps.
    local position=8
    position=$(( position + 4 + $(read_state_length "$state_file" "$position") ))

    local candidate_name
    local field_length
    for candidate_name in lastModifiedAt lastSyncedAt lastReplicatedAt; do
        field_length=$(read_state_length "$state_file" "$position")
        position=$(( position + 4 ))
        if [ "$candidate_name" = "$field_name" ]; then
            if [ "$field_length" -gt 0 ]; then
                tail -c "+$(( position + 1 ))" "$state_file" | head -c "$field_length"
            fi
            return 0
        fi
        position=$(( position + field_length ))
    done
}

#
# Asserts that a string is a valid ISO 8601 date-time.
#
expect_valid_iso_date() {
    local value="$1"
    local description="$2"

    # Matched against the ISO 8601 date-time shape directly. This is stricter than the Date.parse
    # check it replaces, which also accepted plenty of strings that are not ISO 8601 at all.
    local iso_pattern='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})$'
    if [[ "$value" =~ $iso_pattern ]]; then
        log_success "$description: $value"
    else
        log_error "$description: $value is not a valid ISO date"
        exit 1
    fi
}

test_config_timestamps() {
    local test_number="$1"
    print_test_header "$test_number" "DATABASE STATE TIMESTAMPS"

    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"

    # ── 1. add bumps lastModifiedAt ──────────────────────────────────────────
    local db_dir="$test_dir/db-add"
    rm -rf "$db_dir"
    invoke_command "Initialize database" "$(get_cli_command) init --db $db_dir --yes"

    local before_modified=$(read_state_field "$db_dir" "lastModifiedAt")
    if [ -n "$before_modified" ]; then
        log_error "Fresh database should not have lastModifiedAt set, got: $before_modified"
        exit 1
    fi
    log_success "Fresh database has no lastModifiedAt"

    invoke_command "Add PNG file" "$(get_cli_command) add --db $db_dir $TEST_FILES_DIR/test.png --yes"

    local after_add_modified=$(read_state_field "$db_dir" "lastModifiedAt")
    expect_valid_iso_date "$after_add_modified" "lastModifiedAt set after add"

    # ── 2. sync stamps both sides with the same lastSyncedAt ─────────────────
    local source_dir="$test_dir/db-sync-source"
    local replica_dir="$test_dir/db-sync-replica"
    rm -rf "$source_dir" "$replica_dir"

    invoke_command "Initialize sync source database" "$(get_cli_command) init --db $source_dir --yes"
    invoke_command "Add file to sync source" "$(get_cli_command) add --db $source_dir $TEST_FILES_DIR/test.jpg --yes"
    invoke_command "Replicate to create sync target" "$(get_cli_command) replicate --db $source_dir --dest $replica_dir --yes --force"

    # After replication the two databases are identical. Add another file to the source so the
    # databases differ and the following sync actually has work to do (and stamps lastSyncedAt).
    invoke_command "Add another file to sync source" "$(get_cli_command) add --db $source_dir $TEST_FILES_DIR/test.png --yes"

    invoke_command "Sync source and replica" "$(get_cli_command) sync --db $source_dir --dest $replica_dir --yes"

    local source_synced=$(read_state_field "$source_dir" "lastSyncedAt")
    local replica_synced=$(read_state_field "$replica_dir" "lastSyncedAt")

    expect_valid_iso_date "$source_synced" "Source database lastSyncedAt"
    expect_valid_iso_date "$replica_synced" "Replica database lastSyncedAt"
    expect_value "$source_synced" "$replica_synced" "Source and replica lastSyncedAt match"

    # ── 2b. a second sync early-outs because the databases are now identical ──
    # The early-out does no work, so lastSyncedAt must be unchanged from the first sync.
    invoke_command "Sync again (should early-out)" "$(get_cli_command) sync --db $source_dir --dest $replica_dir --yes"

    local source_synced_again=$(read_state_field "$source_dir" "lastSyncedAt")
    expect_value "$source_synced_again" "$source_synced" "Second identical sync early-outs (lastSyncedAt unchanged)"

    # ── 3. repair bumps lastModifiedAt when records need repair ──────────────
    local repair_db_dir="$test_dir/db-repair"
    local repair_source_dir="$test_dir/db-repair-source"
    rm -rf "$repair_db_dir" "$repair_source_dir"

    invoke_command "Initialize repair source database" "$(get_cli_command) init --db $repair_source_dir --yes"
    invoke_command "Add file to repair source" "$(get_cli_command) add --db $repair_source_dir $TEST_FILES_DIR/test.png --yes"
    invoke_command "Replicate to create repair target" "$(get_cli_command) replicate --db $repair_source_dir --dest $repair_db_dir --yes --force"

    # Capture pre-repair lastModifiedAt (the replicated target may not have one yet).
    local before_repair_modified=$(read_state_field "$repair_db_dir" "lastModifiedAt")

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

    local after_repair_modified=$(read_state_field "$repair_db_dir" "lastModifiedAt")
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
