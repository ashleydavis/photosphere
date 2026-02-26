#!/bin/bash

#
# Photosphere CLI Encrypted Database Smoke Tests
# ----------------------------------------------
# This script focuses on encrypted database workflows:
# - init with encryption
# - replicate to/from encrypted databases
# - encrypt/decrypt commands (in-place; plain→encrypted, re-encrypt; same key→exit early)
# - basic CRUD operations on encrypted databases
#

# Ensure deterministic UUIDs and disable colors for parsing
export NODE_ENV=testing
export NO_COLOR=1

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test configuration
TEST_TMP_DIR="${TEST_TMP_DIR:-./test/tmp-encrypted}"
TEST_FILES_DIR="../../test"

# Use built binary instead of bun run start (set by --binary)
USE_BINARY=false

# Track results
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# List of tests in execution order
ENCRYPTED_TESTS=(
    "init-encrypted"
    "replicate-to-encrypted"
    "replicate-from-encrypted"
    "encrypt-plain"
    "encrypt-reencrypt"
    "encrypt-old-to-new-format"
    "decrypt-encrypted"
    "add-encrypted-file"
    "export-encrypted-file"
    "verify-encrypted-db"
    "delete-encrypted-file"
    "list-encrypted-files"
    "replicate-decrypted-from-encrypted"
    "export-with-multiple-keys"
)

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

print_test_header() {
    local name="$1"
    echo ""
    echo "============================================================================"
    echo "Encrypted Smoke Test: $name"
    echo "============================================================================"
}

test_passed() {
    local name="$1"
    ((TESTS_PASSED++))
    log_success "Test '$name' passed"
}

test_failed() {
    local name="$1"
    ((TESTS_FAILED++))
    FAILED_TESTS+=("$name")
    log_error "Test '$name' failed"
}

# Get CLI command (binary or bun run)
get_cli_command() {
    if [ "$USE_BINARY" = "true" ]; then
        # Reuse same paths as main smoke-tests.sh
        local platform
        platform="$(uname | tr '[:upper:]' '[:lower:]')"
        case "$platform" in
            linux*)
                echo "./bin/x64/linux/psi"
                ;;
            darwin*)
                # Default to x64/mac; adjust if arm64 builds are available
                echo "./bin/x64/mac/psi"
                ;;
            msys*|mingw*|cygwin*)
                echo "./bin/x64/win/psi.exe"
                ;;
            *)
                echo "./bin/x64/linux/psi"
                ;;
        esac
    else
        echo "bun run start --"
    fi
}

# Run a command and assert exit code is 0.
# Usage: invoke_command "description" "actual command"
invoke_command() {
    local description="$1"
    local command="$2"

    log_info "$description"
    local output
    output=$(eval "$command" 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "Command failed (exit $exit_code): $command"
        echo "$output"
        return $exit_code
    fi

    echo "$output"
    return 0
}

reset_environment() {
    log_info "Resetting encrypted smoke test environment (TEST_TMP_DIR=$TEST_TMP_DIR)"
    if [ -d "$TEST_TMP_DIR" ]; then
        rm -rf "$TEST_TMP_DIR"
        log_success "Removed $TEST_TMP_DIR"
    else
        log_info "No existing tmp directory to remove"
    fi
}

check_tools() {
    # Delegate to main smoke-tests script so we share the same tool checks
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$script_dir/smoke-tests.sh" ]; then
        TEST_TMP_DIR="$TEST_TMP_DIR" USE_BINARY="$USE_BINARY" bash "$script_dir/smoke-tests.sh" check-tools
    else
        log_error "Cannot find main smoke-tests.sh to run tool checks"
        exit 1
    fi
}

# Ensure directory exists and is empty
prepare_test_dir() {
    local dir="$1"
    rm -rf "$dir"
    mkdir -p "$dir"
}

# Reads the first 4 bytes of a file and prints them as ASCII.
read_magic_tag() {
    local file="$1"
    # Use head and printf to avoid depending on xxd/hexdump formatting
    head -c 4 "$file" 2>/dev/null | LC_ALL=C tr -d '\0'
}

# Asserts that at least one asset file in asset/ is encrypted with the new header.
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

# Asserts that asset files in asset/ are plain (do NOT start with PSEN).
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

# Looks up the asset ID for a given filename using the list command.
get_asset_id_for_filename() {
    local db_dir="$1"
    local key="$2"
    local filename="$3"

    local cli
    cli="$(get_cli_command)"

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

# -----------------------------------------------------------------------------
# Individual tests
# -----------------------------------------------------------------------------

test_init_encrypted() {
    local name="init-encrypted"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/db"
    local key_path="$test_dir/key1.key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key_path\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    if [ ! -d "$db_dir/.db" ] || [ ! -f "$db_dir/.db/files.dat" ] || [ ! -f "$db_dir/.db/encryption.pub" ]; then
        log_error "Encrypted database metadata not created correctly in $db_dir"
        test_failed "$name"
        return
    fi

    test_passed "$name"
}

test_replicate_to_encrypted() {
    local name="replicate-to-encrypted"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local src_dir="$test_dir/plain-db"
    local dest_dir="$test_dir/encrypted-db"
    local dest_key="$test_dir/dest.key"

    prepare_test_dir "$test_dir"

    invoke_command "Init plain source database" "$cli init --db \"$src_dir\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to plain database" "$cli add --db \"$src_dir\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Replicate to encrypted destination" "$cli replicate --db \"$src_dir\" --dest \"$dest_dir\" --dest-key \"$dest_key\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    if [ ! -f "$dest_dir/.db/encryption.pub" ]; then
        log_error "Encrypted destination missing .db/encryption.pub"
        test_failed "$name"
        return
    fi

    assert_database_assets_encrypted "$dest_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify encrypted destination database" "$cli verify --db \"$dest_dir\" --key \"$dest_key\" --yes" || {
        test_failed "$name"
        return
    }

    test_passed "$name"
}

test_replicate_from_encrypted() {
    local name="replicate-from-encrypted"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local enc_dir="$test_dir/encrypted-db"
    local plain_dir="$test_dir/plain-db"
    local key_path="$test_dir/key1.key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted source database" "$cli init --db \"$enc_dir\" --key \"$key_path\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$enc_dir\" --key \"$key_path\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$enc_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Replicate from encrypted to plain destination" "$cli replicate --db \"$enc_dir\" --dest \"$plain_dir\" --key \"$key_path\" --yes" || {
        test_failed "$name"
        return
    }

    if [ -f "$plain_dir/.db/encryption.pub" ]; then
        log_error "Plain destination should not have .db/encryption.pub"
        test_failed "$name"
        return
    fi

    assert_database_assets_plain "$plain_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify plain destination database" "$cli verify --db \"$plain_dir\" --yes" || {
        test_failed "$name"
        return
    }

    test_passed "$name"
}

test_encrypt_plain() {
    local name="encrypt-plain"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local plain_dir="$test_dir/plain-db"
    local key_path="$test_dir/key1.key"

    prepare_test_dir "$test_dir"

    invoke_command "Init plain source database" "$cli init --db \"$plain_dir\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to plain database" "$cli add --db \"$plain_dir\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Encrypt plain database in place using psi encrypt" "$cli encrypt --db \"$plain_dir\" --key \"$key_path\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    if [ ! -f "$plain_dir/.db/encryption.pub" ]; then
        log_error "Encrypted database missing .db/encryption.pub after psi encrypt"
        test_failed "$name"
        return
    fi

    assert_database_assets_encrypted "$plain_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify encrypted database" "$cli verify --db \"$plain_dir\" --key \"$key_path\" --yes" || {
        test_failed "$name"
        return
    }

    test_passed "$name"
}

test_encrypt_reencrypt() {
    local name="encrypt-reencrypt"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local enc1_dir="$test_dir/encrypted-db-1"
    local key1="$test_dir/key1.key"
    local key2="$test_dir/key2.key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database with key1" "$cli init --db \"$enc1_dir\" --key \"$key1\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file with key1" "$cli add --db \"$enc1_dir\" --key \"$key1\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$enc1_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Re-encrypt database in place with key2" "$cli encrypt --db \"$enc1_dir\" --key \"$key2\" --generate-key --source-key \"$key1\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$enc1_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify re-encrypted database with key2" "$cli verify --db \"$enc1_dir\" --key \"$key2\" --yes" || {
        test_failed "$name"
        return
    }

    # Sanity check: trying to verify with key1 should fail.
    local output
    output=$(eval "$cli verify --db \"$enc1_dir\" --key \"$key1\" --yes" 2>&1)
    if [ $? -eq 0 ]; then
        log_error "Verification of re-encrypted database unexpectedly succeeded with old key"
        echo "$output"
        test_failed "$name"
        return
    fi

    test_passed "$name"
}

test_encrypt_old_to_new_format() {
    local name="encrypt-old-to-new-format"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local old_dir="$test_dir/old-encrypted-db"
    local key="$test_dir/key1.key"

    prepare_test_dir "$test_dir"

    # Encrypt with same key as source: CLI exits early (no rewrite). Database
    # remains encrypted and verifies with that key.

    invoke_command "Init encrypted database (simulated old-format source)" "$cli init --db \"$old_dir\" --key \"$key\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to simulated old-format database" "$cli add --db \"$old_dir\" --key \"$key\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Run psi encrypt in place to convert to new format" "$cli encrypt --db \"$old_dir\" --key \"$key\" --source-key \"$key\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$old_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify converted encrypted database" "$cli verify --db \"$old_dir\" --key \"$key\" --yes" || {
        test_failed "$name"
        return
    }

    test_passed "$name"
}

test_decrypt_encrypted() {
    local name="decrypt-encrypted"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local enc_dir="$test_dir/encrypted-db"
    local key="$test_dir/key1.key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$enc_dir\" --key \"$key\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$enc_dir\" --key \"$key\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$enc_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Decrypt encrypted database in place" "$cli decrypt --db \"$enc_dir\" --key \"$key\" --yes" || {
        test_failed "$name"
        return
    }

    if [ -f "$enc_dir/.db/encryption.pub" ]; then
        log_error "Decrypted database should not have .db/encryption.pub after decrypt"
        test_failed "$name"
        return
    fi

    assert_database_assets_plain "$enc_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify decrypted plain database" "$cli verify --db \"$enc_dir\" --yes" || {
        test_failed "$name"
        return
    }

    test_passed "$name"
}

test_add_encrypted_file() {
    local name="add-encrypted-file"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/encrypted-db"
    local key="$test_dir/key1.key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$db_dir\" --key \"$key\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$db_dir" || {
        test_failed "$name"
        return
    }

    test_passed "$name"
}

test_export_encrypted_file() {
    local name="export-encrypted-file"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/encrypted-db"
    local export_dir="$test_dir/export"
    local key="$test_dir/key1.key"

    prepare_test_dir "$test_dir"
    mkdir -p "$export_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$db_dir\" --key \"$key\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    local asset_id
    asset_id=$(get_asset_id_for_filename "$db_dir" "$key" "test.png") || {
        test_failed "$name"
        return
    }

    local export_path="$export_dir/exported.png"
    invoke_command "Export encrypted asset" "$cli export --db \"$db_dir\" --key \"$key\" \"$asset_id\" \"$export_path\" --yes" || {
        test_failed "$name"
        return
    }

    if [ ! -f "$export_path" ]; then
        log_error "Expected exported file not found: $export_path"
        test_failed "$name"
        return
    fi

    # Exported file should be plain (no PSEN header).
    local tag
    tag=$(read_magic_tag "$export_path")
    if [ "$tag" = "PSEN" ]; then
        log_error "Exported file appears to be encrypted (has PSEN header): $export_path"
        test_failed "$name"
        return
    fi

    test_passed "$name"
}

test_verify_encrypted_db() {
    local name="verify-encrypted-db"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/encrypted-db"
    local key="$test_dir/key1.key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$db_dir\" --key \"$key\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$db_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify encrypted database" "$cli verify --db \"$db_dir\" --key \"$key\" --yes" || {
        test_failed "$name"
        return
    }

    test_passed "$name"
}

test_delete_encrypted_file() {
    local name="delete-encrypted-file"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/encrypted-db"
    local key="$test_dir/key1.key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$db_dir\" --key \"$key\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    local asset_id
    asset_id=$(get_asset_id_for_filename "$db_dir" "$key" "test.png") || {
        test_failed "$name"
        return
    }

    invoke_command "Remove asset from encrypted database" "$cli remove --db \"$db_dir\" --key \"$key\" \"$asset_id\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify encrypted database after delete" "$cli verify --db \"$db_dir\" --key \"$key\" --yes" || {
        test_failed "$name"
        return
    }

    test_passed "$name"
}

test_list_encrypted_files() {
    local name="list-encrypted-files"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/encrypted-db"
    local key="$test_dir/key1.key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$db_dir\" --key \"$key\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$db_dir" || {
        test_failed "$name"
        return
    }

    local list_output
    list_output=$(invoke_command "List files in encrypted database" "$cli list --db \"$db_dir\" --key \"$key\" --yes") || {
        test_failed "$name"
        return
    }

    if ! echo "$list_output" | grep -q "test.png"; then
        log_error "List output does not reference added asset"
        echo "$list_output"
        test_failed "$name"
        return
    fi

    test_passed "$name"
}

test_replicate_decrypted_from_encrypted() {
    local name="replicate-decrypted-from-encrypted"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local enc_dir="$test_dir/encrypted-db"
    local plain_dir="$test_dir/plain-db"
    local key="$test_dir/key1.key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$enc_dir\" --key \"$key\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$enc_dir\" --key \"$key\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$enc_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Replicate from encrypted to plain destination" "$cli replicate --db \"$enc_dir\" --dest \"$plain_dir\" --key \"$key\" --yes" || {
        test_failed "$name"
        return
    }

    if [ -f "$plain_dir/.db/encryption.pub" ]; then
        log_error "Plain replica should not have .db/encryption.pub"
        test_failed "$name"
        return
    fi

    assert_database_assets_plain "$plain_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify plain replica" "$cli verify --db \"$plain_dir\" --yes" || {
        test_failed "$name"
        return
    }

    test_passed "$name"
}

test_export_with_multiple_keys() {
    local name="export-with-multiple-keys"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/encrypted-db"
    local export_dir="$test_dir/export"
    local key1="$test_dir/key1.key"
    local key2="$test_dir/key2.key"

    prepare_test_dir "$test_dir"
    mkdir -p "$export_dir"

    # Create encrypted database with key1
    invoke_command "Init encrypted database with key1" "$cli init --db \"$db_dir\" --key \"$key1\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    # Ensure key2 also exists on disk (generate it using a throwaway database).
    invoke_command "Generate secondary key2 in throwaway database" "$cli init --db \"$test_dir/tmp-key2-db\" --key \"$key2\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    # Add two files to the encrypted database.
    invoke_command "Add first PNG (key1)" "$cli add --db \"$db_dir\" --key \"$key1\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add second JPG (key1)" "$cli add --db \"$db_dir\" --key \"$key1\" \"$TEST_FILES_DIR/test.jpg\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$db_dir" || {
        test_failed "$name"
        return
    }

    # Look up asset IDs via list.
    local asset_id1
    asset_id1=$(get_asset_id_for_filename "$db_dir" "$key1" "test.png") || {
        test_failed "$name"
        return
    }

    local asset_id2
    asset_id2=$(get_asset_id_for_filename "$db_dir" "$key1" "test.jpg") || {
        test_failed "$name"
        return
    }

    # Export both assets using a comma-separated key list (multi-key map).
    local multi_keys="$key1,$key2"
    local export1="$export_dir/export1.png"
    local export2="$export_dir/export2.jpg"

    invoke_command "Export first asset with multiple keys" "$cli export --db \"$db_dir\" --key \"$multi_keys\" \"$asset_id1\" \"$export1\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Export second asset with multiple keys" "$cli export --db \"$db_dir\" --key \"$multi_keys\" \"$asset_id2\" \"$export2\" --yes" || {
        test_failed "$name"
        return
    }

    if [ ! -f "$export1" ] || [ ! -f "$export2" ]; then
        log_error "Expected exported files not found in $export_dir"
        test_failed "$name"
        return
    fi

    local tag1 tag2
    tag1=$(read_magic_tag "$export1")
    tag2=$(read_magic_tag "$export2")
    if [ "$tag1" = "PSEN" ] || [ "$tag2" = "PSEN" ]; then
        log_error "Exported files appear to be encrypted (found PSEN header)"
        test_failed "$name"
        return
    fi

    test_passed "$name"
}

# -----------------------------------------------------------------------------
# Test runner
# -----------------------------------------------------------------------------

run_single_test() {
    local name="$1"

    case "$name" in
        init-encrypted)                    test_init_encrypted ;;
        replicate-to-encrypted)            test_replicate_to_encrypted ;;
        replicate-from-encrypted)          test_replicate_from_encrypted ;;
        encrypt-plain)                    test_encrypt_plain ;;
        encrypt-reencrypt)                test_encrypt_reencrypt ;;
        encrypt-old-to-new-format)        test_encrypt_old_to_new_format ;;
        decrypt-encrypted)                test_decrypt_encrypted ;;
        add-encrypted-file)               test_add_encrypted_file ;;
        export-encrypted-file)            test_export_encrypted_file ;;
        verify-encrypted-db)              test_verify_encrypted_db ;;
        delete-encrypted-file)            test_delete_encrypted_file ;;
        list-encrypted-files)             test_list_encrypted_files ;;
        replicate-decrypted-from-encrypted) test_replicate_decrypted_from_encrypted ;;
        export-with-multiple-keys)        test_export_with_multiple_keys ;;
        *)
            log_error "Unknown test: $name"
            return 1
            ;;
    esac
}

run_all_tests() {
    reset_environment
    check_tools

    for name in "${ENCRYPTED_TESTS[@]}"; do
        run_single_test "$name"
    done

    echo ""
    echo "Encrypted smoke tests completed."
    echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"

    if [ $TESTS_FAILED -ne 0 ]; then
        echo -e "${RED}Failed tests:${NC}"
        for t in "${FAILED_TESTS[@]}"; do
            echo "  - $t"
        done
        exit 1
    fi
}

show_usage() {
    echo "Usage: $0 [options] [command]"
    echo ""
    echo "Commands:"
    echo "  all                 Run all encrypted smoke tests"
    echo "  reset               Clean up encrypted test artifacts"
    echo "  <test-name>         Run a single encrypted test"
    echo ""
    echo "Options:"
    echo "  -b, --binary        Use built CLI binary instead of bun run start --"
    echo "  -t, --tmp-dir PATH  Override test tmp directory (default: ./test/tmp-encrypted)"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Available tests:"
    for name in "${ENCRYPTED_TESTS[@]}"; do
        echo "  - $name"
    done
}

main() {
    local positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--binary)
                USE_BINARY=true
                shift
                ;;
            -t|--tmp-dir)
                if [ $# -lt 2 ]; then
                    log_error "Option $1 requires a directory argument"
                    exit 1
                fi
                TEST_TMP_DIR="$2"
                shift 2
                ;;
            --tmp-dir=*)
                TEST_TMP_DIR="${1#*=}"
                shift
                ;;
            -h|--help|help)
                show_usage
                exit 0
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    set -- "${positional[@]}"

    # Default command is "all"
    local command="${1:-all}"

    case "$command" in
        all)
            run_all_tests
            ;;
        reset)
            reset_environment
            ;;
        *)
            # Single test
            check_tools
            run_single_test "$command"
            if [ $TESTS_FAILED -ne 0 ]; then
                exit 1
            fi
            ;;
    esac
}

main "$@"

