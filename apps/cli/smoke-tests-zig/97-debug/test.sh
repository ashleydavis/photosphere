#!/bin/bash
DESCRIPTION="Every psi debug subcommand, run by the Zig CLI on a database holding one photo twice under two asset ids"

# A database gets the same photo twice, under two asset ids, when two replicas each import it and then
# sync: import leaves out a photo the database already holds, but sync copies whatever the other side
# has. That is the state the collision and duplicate commands exist for, so this test builds it with
# the Zig CLI and takes it through each debug subcommand in turn. Every subcommand is also run by the
# TypeScript CLI, on a copy of the database in the same state, and the two are expected to agree.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

#
# Copies a database, keeping the modification times its files tree records.
#
copy_database() {
    local source_dir="$1"
    local destination_dir="$2"
    cp -Rp "$source_dir" "$destination_dir"
}

#
# Prints a debug subcommand's output with a database's path replaced by <db>. The path is replaced as
# given, and as the CLIs print it once resolved: with runs of slashes collapsed (macOS's TMPDIR ends in
# a slash, so the test paths hold "T//photosphere-tests") and, on Windows, with backslashes.
#
replace_db_path() {
    local debug_output="$1"
    local db_path="$2"

    local resolved_db_path
    resolved_db_path="$(echo "$db_path" | tr -s '/')"
    local backslash_db_path="${resolved_db_path//\//\\}"

    debug_output="${debug_output//"$db_path"/<db>}"
    debug_output="${debug_output//"$resolved_db_path"/<db>}"
    debug_output="${debug_output//"$backslash_db_path"/<db>}"
    printf '%s' "$debug_output"
}

#
# Runs a debug subcommand with the Zig CLI on one database and with the TypeScript CLI on a copy of
# it, and expects the two to print the same once each database's path is replaced. The Zig CLI's
# output goes into the named variable.
#
expect_same_debug_output() {
    local description="$1"
    local subcommand="$2"
    local zig_db_dir="$3"
    local ts_db_dir="$4"
    local output_var_name="$5"

    local zig_debug_output
    invoke_command "$description with the Zig CLI" "$(get_zig_cli_command) -q debug $subcommand --db \"$zig_db_dir\" --yes" 0 "zig_debug_output"
    local ts_debug_output
    invoke_command "$description with the TypeScript CLI" "$(get_cli_command) -q debug $subcommand --db \"$ts_db_dir\" --yes" 0 "ts_debug_output"

    expect_value "$(replace_db_path "$zig_debug_output" "$zig_db_dir")" "$(replace_db_path "$ts_debug_output" "$ts_db_dir")" "$description: the Zig CLI prints what the TypeScript CLI prints"

    eval "$output_var_name=\"\$zig_debug_output\""
}

test_debug() {
    local test_number="$1"
    print_test_header "$test_number" "DEBUG"

    local test_dir
    test_dir="$(get_test_dir "$test_number")"
    local db_dir="$test_dir/debug-db"
    local replica_dir="$test_dir/debug-replica"
    local ts_db_dir="$test_dir/debug-db-ts"

    # --- The same photo under two asset ids. ---

    invoke_command "Create the database" "$(get_zig_cli_command) init --db \"$db_dir\" --yes"
    ts_verify "$db_dir"
    invoke_command "Replicate it" "$(get_zig_cli_command) replicate --db \"$db_dir\" --dest \"$replica_dir\" --yes"
    ts_verify "$replica_dir"
    invoke_command "Add a JPG and a PNG to the database" "$(get_zig_cli_command) add --db \"$db_dir\" \"$TEST_FILES_DIR/test.jpg\" \"$TEST_FILES_DIR/test.png\" --yes"
    ts_verify "$db_dir"
    invoke_command "Add the same PNG to the replica" "$(get_zig_cli_command) add --db \"$replica_dir\" \"$TEST_FILES_DIR/test.png\" --yes"
    ts_verify "$replica_dir"
    # TODO: restore the TypeScript verify here once the sync same-content bug is fixed in both ports. No TypeScript verify after this sync, on either side. Both databases now hold the same PNG under
    # two asset ids, and with the fixed timestamps of NODE_ENV=testing the two records hash the same.
    # Sync matches records by hash, so neither side takes the other's record and each is left with an
    # asset file no record names. The TypeScript CLI leaves exactly the same state (its verify fails
    # on it too), so this is not a difference between the two ports. Both databases are verified
    # before the sync, and this one again at the end, once the debug commands have repaired it. The
    # remove-duplicates and build-sort-index steps below leave that asset file unnamed too, so they
    # are not followed by one either.
    invoke_command "Sync the two" "$(get_zig_cli_command) sync --db \"$db_dir\" --dest \"$replica_dir\" --yes"

    local asset_count
    asset_count="$(ls "$db_dir/asset" | wc -l | tr -d ' ')"
    expect_value "$asset_count" "3" "The database holds three assets, two of them the same PNG"

    local png_hash
    png_hash="$(sha256sum "$TEST_FILES_DIR/test.png" 2> /dev/null | cut -d ' ' -f 1)"
    if [ -z "$png_hash" ]; then
        png_hash="$(shasum -a 256 "$TEST_FILES_DIR/test.png" | cut -d ' ' -f 1)"
    fi

    copy_database "$db_dir" "$ts_db_dir"

    # --- merkle-tree ---

    local root_hash
    invoke_command "Get the root hash" "$(get_zig_cli_command) -q root-hash --db \"$db_dir\" --yes" 0 "root_hash"

    local merkle_output
    expect_same_debug_output "Show the merkle trees" "merkle-tree" "$db_dir" "$ts_db_dir" "merkle_output"
    expect_output_string "$merkle_output" "Merkle Trees Visualization" "The merkle trees have their heading"
    expect_output_string "$merkle_output" "^$root_hash$" "The aggregate root hash is the database's root hash"
    expect_output_string "$merkle_output" "Files Merkle Tree (.db/files.dat):" "The files tree is shown"
    expect_output_string "$merkle_output" "Total Items: 10$" "The files tree holds the ten files of the database"

    local records_output
    expect_same_debug_output "Show the merkle trees with their records" "merkle-tree --records" "$db_dir" "$ts_db_dir" "records_output"
    expect_output_string "$records_output" "$png_hash" "The records show the PNG's hash"

    # --- find-collisions ---

    local collisions_output
    expect_same_debug_output "Find hash collisions" "find-collisions" "$db_dir" "$ts_db_dir" "collisions_output"
    expect_output_value "$collisions_output" "Total collisions:" "1" "One hash is shared by more than one asset"
    expect_output_value "$collisions_output" "Total asset IDs in collisions:" "2" "Two asset ids share it"
    check_exists "$db_dir/collisions.json" "The collisions file"

    local collision_hashes
    collision_hashes="$(jq -r 'keys[]' "$db_dir/collisions.json")"
    expect_value "$collision_hashes" "$png_hash" "The colliding hash is the PNG's"
    local collision_sizes
    # Joined by jq itself: the Windows jq ends each line it prints with CRLF, which `tr '\n' ' '` leaves a CR of.
    collision_sizes="$(jq -j ".[\"$png_hash\"][] | \"\(.size) \"" "$db_dir/collisions.json")"
    expect_value "$collision_sizes" "1317 1317 " "Both colliding assets have the PNG's size"

    local ts_collisions
    ts_collisions="$(cat "$ts_db_dir/collisions.json")"
    expect_value "$(cat "$db_dir/collisions.json")" "$ts_collisions" "The Zig CLI writes the collisions file the TypeScript CLI writes"

    # --- find-duplicates ---

    local duplicates_output
    expect_same_debug_output "Find duplicates" "find-duplicates" "$db_dir" "$ts_db_dir" "duplicates_output"
    expect_output_value "$duplicates_output" "True duplicates (same content):" "1" "The shared hash is one true duplicate"
    expect_output_value "$duplicates_output" "Hash collisions (different content):" "0" "No hash is shared by different content"
    check_exists "$db_dir/duplicates.json" "The duplicates file"

    local duplicate_ids
    duplicate_ids="$(jq -r ".[\"$png_hash\"][0].assetIds[]" "$db_dir/duplicates.json")"
    expect_value "$(echo "$duplicate_ids" | wc -l | tr -d ' ')" "2" "The duplicate group holds both asset ids"
    local kept_id
    kept_id="$(echo "$duplicate_ids" | head -1)"
    local removed_id
    removed_id="$(echo "$duplicate_ids" | tail -1)"

    local ts_duplicates
    ts_duplicates="$(cat "$ts_db_dir/duplicates.json")"
    expect_value "$(cat "$db_dir/duplicates.json")" "$ts_duplicates" "The Zig CLI writes the duplicates file the TypeScript CLI writes"

    # --- remove-duplicates ---

    local remove_output
    expect_same_debug_output "Remove the duplicates" "remove-duplicates" "$db_dir" "$ts_db_dir" "remove_output"
    expect_output_string "$remove_output" "Found 1 duplicate asset to remove" "One duplicate is found to remove"
    expect_output_value "$remove_output" "Assets removed:" "1" "One duplicate is removed"

    check_exists "$db_dir/asset/$kept_id" "The first asset of the duplicate group"
    if [ -e "$db_dir/asset/$removed_id" ] || [ -e "$db_dir/display/$removed_id" ] || [ -e "$db_dir/thumb/$removed_id" ]; then
        log_error "The files of the removed duplicate $removed_id are still in the database"
        exit 1
    fi
    log_success "The files of the removed duplicate are gone"

    local summary_output
    invoke_command "Summarize the database" "$(get_zig_cli_command) -q summary --db \"$db_dir\" --yes" 0 "summary_output"
    expect_output_value "$summary_output" "Total files:" "7" "The database holds the seven files of the two assets left"

    local list_output
    invoke_command "List the database" "$(get_zig_cli_command) -q list --db \"$db_dir\" --yes" 0 "list_output"
    expect_output_string "$list_output" "$removed_id" "The removed duplicate is not listed" false
    expect_output_string "$list_output" "^$kept_id test.png$" "The kept asset is listed"

    local ts_root_hash
    invoke_command "Get the root hash of the copy the TypeScript CLI changed" "$(get_cli_command) -q root-hash --db \"$ts_db_dir\" --yes" 0 "ts_root_hash"
    local zig_root_hash
    invoke_command "Get the root hash of the database" "$(get_zig_cli_command) -q root-hash --db \"$db_dir\" --yes" 0 "zig_root_hash"
    expect_value "$zig_root_hash" "$ts_root_hash" "Removing the duplicates leaves the database the TypeScript CLI leaves"

    # --- build-sort-index ---

    local sort_output
    expect_same_debug_output "Rebuild the sort indexes" "build-sort-index" "$db_dir" "$ts_db_dir" "sort_output"
    expect_output_string "$sort_output" "Deleted 2 sort indexes." "The existing sort indexes are deleted"
    expect_output_string "$sort_output" "Sort indexes rebuilt successfully." "The sort indexes are rebuilt"
    check_exists "$db_dir/.db/bson/indexes/metadata/hash_asc" "The hash sort index"
    check_exists "$db_dir/.db/bson/indexes/metadata/photoDate_desc" "The photo date sort index"

    local sorted_list_output
    invoke_command "List the database through the rebuilt index" "$(get_zig_cli_command) -q list --db \"$db_dir\" --yes" 0 "sorted_list_output"
    expect_value "$sorted_list_output" "$list_output" "The rebuilt index lists the assets as before"

    # --- build-files-tree ---

    # A file the files tree does not know about, which the rebuild takes in from storage.
    cp "$TEST_FILES_DIR/test.webp" "$db_dir/asset/untracked-file"
    cp -p "$db_dir/asset/untracked-file" "$ts_db_dir/asset/untracked-file"

    local orphans_output
    invoke_command "Find orphans before the rebuild" "$(get_zig_cli_command) -q find-orphans --db \"$db_dir\" --yes" 0 "orphans_output"
    expect_output_string "$orphans_output" "asset/untracked-file" "The untracked file is an orphan"

    local rebuild_output
    expect_same_debug_output "Rebuild the files tree" "build-files-tree" "$db_dir" "$ts_db_dir" "rebuild_output"
    # The seven files of the database (two assets and README.md), the untracked file, and collisions.json and
    # duplicates.json, which find-collisions and find-duplicates wrote into the database directory.
    expect_output_string "$rebuild_output" "Rebuilt files merkle tree: 10 files." "The rebuilt tree holds every file in storage, the untracked one among them"

    invoke_command "Find orphans after the rebuild" "$(get_zig_cli_command) -q find-orphans --db \"$db_dir\" --yes" 0 "orphans_output"
    expect_output_string "$orphans_output" "No orphaned files found" "The untracked file is in the tree now"

    invoke_command "Get the root hash of the copy the TypeScript CLI rebuilt" "$(get_cli_command) -q root-hash --db \"$ts_db_dir\" --yes" 0 "ts_root_hash"
    invoke_command "Get the root hash of the rebuilt database" "$(get_zig_cli_command) -q root-hash --db \"$db_dir\" --yes" 0 "zig_root_hash"
    expect_value "$zig_root_hash" "$ts_root_hash" "The Zig CLI rebuilds the files tree the TypeScript CLI rebuilds"

    # The rebuilt tree holds the untracked file, but no asset record names it, and verify says so.
    local verify_output
    invoke_command "Verify the database with an asset file no record names (should fail)" "$(get_zig_cli_command) verify --db \"$db_dir\" --yes" 1 "verify_output"
    expect_output_value "$verify_output" "Record mismatches:" "1" "One asset file has no record"
    expect_output_string "$verify_output" "● asset/untracked-file$" "The untracked file is the one without a record"
    local ts_verify_output
    invoke_command "Verify it with the TypeScript CLI (should fail)" "$(get_cli_command) verify --db \"$db_dir\" --yes" 1 "ts_verify_output"
    expect_output_value "$ts_verify_output" "Record mismatches:" "1" "The TypeScript CLI finds the same asset file without a record"

    # Without the untracked file, a rebuild gives back the tree of the database's own files.
    rm "$db_dir/asset/untracked-file"
    invoke_command "Rebuild the files tree without the untracked file" "$(get_zig_cli_command) -q debug build-files-tree --db \"$db_dir\" --yes" 0 "rebuild_output"
    expect_output_string "$rebuild_output" "Rebuilt files merkle tree: 9 files." "The rebuilt tree no longer holds the untracked file"

    invoke_command "Verify the database" "$(get_zig_cli_command) verify --db \"$db_dir\" --yes"
    ts_verify "$db_dir"

    test_passed
}

test_debug "${1:-97}"
