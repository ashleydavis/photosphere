#!/bin/bash
DESCRIPTION="Edit an asset's metadata and read it back through the CLI"

# The CLI half of a trio: apps/desktop/smoke-tests/34-edit-asset-metadata and
# apps/smoke-tests/tests/46-edit-asset-metadata cover the same behaviour on the other two shells. The
# behaviour is: a metadata edit made against a database lands in it, and the normal read path reports
# the new value rather than the old one.
#
# What this one does NOT cover, and the reason it is written differently from its two siblings: the
# CLI has no route to applyDatabaseOps. That function is reached only through POST
# /apply-database-ops on the asset server (packages/node-api/src/lib/asset-server-routes.ts), which
# the desktop and mobile shells run and the CLI does not, and there is no `psi` command that edits an
# asset's metadata at all. So this exercises the layer underneath instead: the edit is written
# straight into the BSON collection with bdb, the same tool test 37 uses, and read back with
# `psi info`. Treat a pass here as saying the storage and read halves are sound, and look to the
# desktop and mobile tests for whether the endpoint above them works.
#
# Reading back with `psi info` rather than with bdb is the point of the test. bdb reporting what bdb
# just wrote would prove only that bdb is self-consistent; `psi info` opens the database through the
# same code the rest of the CLI uses, so it is the reader a user would actually meet.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_edit_asset_metadata() {
    local test_number="$1"
    print_test_header "$test_number" "EDIT ASSET METADATA"

    local test_dir
    test_dir="$(get_test_dir "$test_number")"
    local db_dir="$test_dir/edit-db"
    local new_description="Edited through the database"

    rm -rf "$test_dir"
    mkdir -p "$test_dir"

    # A database of this test's own, rather than one of the checked-in fixtures, because this writes
    # to it. One asset is all the endpoint's behaviour needs.
    invoke_command "Create the database" \
        "$(get_cli_command) init --db \"$db_dir\" --yes" 0
    invoke_command "Add a photo to the database" \
        "$(get_cli_command) add \"$TEST_FILES_DIR/test.jpg\" --db \"$db_dir\" --yes" 0

    # The asset's id is whatever `add` generated, so it is read out of the listing rather than
    # hardcoded the way test 37 hardcodes its v6 fixture's id.
    local list_output record_id
    invoke_command "List the database" \
        "$(get_cli_command) list --db \"$db_dir\" --yes" 0 "list_output"
    record_id="$(echo "$list_output" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
    if [ -z "$record_id" ]; then
        log_error "Could not find the asset's id in the output of 'psi list'. It said:"
        echo "$list_output" | sed 's/^/  /'
        return 1
    fi
    log_info "Asset id: $record_id"

    # The description starts out unset, so the read below cannot pass on a value that was already
    # there. Asserted rather than assumed, because a fixture that arrived with one would make the
    # whole test vacuous and it would still go green.
    local before_output
    invoke_command "Read the asset before the edit" \
        "$(get_cli_command) info $record_id --db \"$db_dir\" --yes" 0 "before_output"
    expect_output_string "$before_output" "$new_description" "The description is not set before the edit" "false"

    invoke_command "Set the description in the database" \
        "$(get_bdb_command) edit \"$db_dir/.db/bson\" metadata $record_id description string \"$new_description\"" 0

    local after_output
    invoke_command "Read the asset after the edit" \
        "$(get_cli_command) info $record_id --db \"$db_dir\" --yes" 0 "after_output"
    expect_output_string "$after_output" "$new_description" "The edited description is reported by 'psi info'"

    test_passed
}

test_edit_asset_metadata "${1:-80}"
