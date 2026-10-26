#!/bin/bash

# Helpers shared by the encrypted database smoke tests (105 to 124). Sourced after common.sh, which
# provides log_error, log_success and get_zig_cli_command. See encrypted.md beside this file.

#
# Reads the first 4 bytes of a file and prints them as ASCII. An encrypted asset starts with PSEN.
# Usage: read_magic_tag <file>
#
read_magic_tag() {
    local file="$1"
    # Use head and printf to avoid depending on xxd/hexdump formatting
    head -c 4 "$file" 2>/dev/null | LC_ALL=C tr -d '\0'
}

#
# Returns 0 when the first asset file in the database's asset/ directory starts with the PSEN
# header, and 1 (with the reason logged) when it does not or when there is no asset to look at.
# Usage: assert_database_assets_encrypted <db_dir>
#
assert_database_assets_encrypted() {
    local db_dir="$1"
    local asset_dir="$db_dir/asset"

    if [ ! -d "$asset_dir" ]; then
        log_error "Expected asset directory not found: $asset_dir"
        return 1
    fi

    local first_file
    first_file=$(find "$asset_dir" -type f | head -n 1)
    if [ -z "$first_file" ]; then
        log_error "No asset files found under $asset_dir"
        return 1
    fi

    local tag
    tag=$(read_magic_tag "$first_file")
    if [ "$tag" != "PSEN" ]; then
        log_error "Expected encrypted asset to start with tag 'PSEN', got '$tag' (file: $first_file)"
        return 1
    fi

    log_success "Verified encrypted asset header for $first_file"
    return 0
}

#
# Returns 0 when the first asset file in the database's asset/ directory does not start with the PSEN
# header, and 1 (with the reason logged) when it does or when there is no asset to look at.
# Usage: assert_database_assets_plain <db_dir>
#
assert_database_assets_plain() {
    local db_dir="$1"
    local asset_dir="$db_dir/asset"

    if [ ! -d "$asset_dir" ]; then
        log_error "Expected asset directory not found: $asset_dir"
        return 1
    fi

    local first_file
    first_file=$(find "$asset_dir" -type f | head -n 1)
    if [ -z "$first_file" ]; then
        log_error "No asset files found under $asset_dir"
        return 1
    fi

    local tag
    tag=$(read_magic_tag "$first_file")
    if [ "$tag" = "PSEN" ]; then
        log_error "Expected plain asset (no PSEN tag), but found encrypted header in $first_file"
        return 1
    fi

    log_success "Verified plain asset header for $first_file"
    return 0
}

#
# Prints the asset ID of the file with the given name, read from the Zig CLI's list output. The key
# may be empty for a plain database. Returns 1 (with the reason printed) when the list fails or names
# no such file.
# Usage: asset_id=$(get_asset_id_for_filename <db_dir> <key> <filename>)
#
get_asset_id_for_filename() {
    local db_dir="$1"
    local key="$2"
    local filename="$3"

    local cli
    cli="$(get_zig_cli_command)"

    local cmd="$cli list --db \"$db_dir\" --yes"
    if [ -n "$key" ]; then
        cmd="$cmd --key \"$key\""
    fi

    local output
    output=$(eval "$cmd" 2>&1)
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Failed to list database files for $db_dir (exit $exit_code)"
        echo "$output"
        return 1
    fi

    # Find the line that contains the filename and extract the first column as the asset ID.
    local line
    line=$(echo "$output" | grep " $filename" | head -n 1)
    if [ -z "$line" ]; then
        log_error "Failed to find asset line for $filename in list output"
        echo "$output"
        return 1
    fi

    local asset_id
    asset_id=$(echo "$line" | awk '{print $1}')
    if [ -z "$asset_id" ]; then
        log_error "Failed to parse asset ID for $filename from list output line:"
        echo "$line"
        return 1
    fi

    echo "$asset_id"
    return 0
}
