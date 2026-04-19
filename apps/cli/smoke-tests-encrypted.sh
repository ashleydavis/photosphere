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

# Isolate the vault and config so tests don't pollute the user's real data.
export PHOTOSPHERE_VAULT_DIR="${TEST_TMP_DIR}/vault"
export PHOTOSPHERE_CONFIG_DIR="${TEST_TMP_DIR}/config"

# Use built binary instead of bun run start (set by --binary)
USE_BINARY=false

# Track results
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# Trap to show summary on exit (including failures)
cleanup_and_show_summary() {
    local exit_code=$?
    echo ""

    # Show final status message - this should be the last thing printed
    echo ""
    echo "============================================================================"
    echo "============================================================================"
    if [ $TESTS_FAILED -eq 0 ] && [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓✓✓ ALL SMOKE TESTS PASSED ✓✓✓${NC}"
        echo -e "${GREEN}Tests Passed: $TESTS_PASSED${NC}"
    else
        echo -e "${RED}✗✗✗ SMOKE TESTS FAILED ✗✗✗${NC}"
        echo -e "${RED}Exit Code: $exit_code${NC}"
        if [ $TESTS_FAILED -gt 0 ]; then
            echo -e "${RED}Tests Failed: $TESTS_FAILED${NC}"
            if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
                echo -e "${RED}Failed Tests:${NC}"
                for failed_test in "${FAILED_TESTS[@]}"; do
                    echo -e "${RED}  - $failed_test${NC}"
                done
            fi
        else
            echo -e "${RED}Test execution was aborted (likely due to an assertion failure)${NC}"
        fi
        if [ $TESTS_PASSED -gt 0 ]; then
            echo -e "${GREEN}Tests Passed: $TESTS_PASSED${NC}"
        fi
    fi
    echo "============================================================================"
    echo "============================================================================"

    # Exit with the appropriate code
    exit $exit_code
}

trap cleanup_and_show_summary EXIT

# List of tests in execution order.
#
# Test descriptions:
#   init-encrypted
#     Create a new database with encryption using a generated key; checks .db metadata and encryption.pub.
#   replicate-to-encrypted
#     Init plain DB, add a file, replicate to an encrypted destination; verifies destination is encrypted and verifies.
#   replicate-from-encrypted
#     Init encrypted DB, add a file, replicate to a plain destination; verifies destination is plain and verifies.
#   encrypt-plain
#     Init plain DB, add a file, run psi encrypt in place; verifies assets have PSEN header and DB verifies with key.
#   encrypt-reencrypt
#     Init encrypted DB with key1, add file, re-encrypt in place with key2; verifies with key2 and that key1 fails.
#   encrypt-old-to-new-format
#     Encrypt in place with same key as source (no-op rewrite); verifies DB remains encrypted and verifies with key.
#   decrypt-encrypted
#     Init encrypted DB, add file, run psi decrypt in place; verifies encryption.pub removed and assets are plain.
#   add-encrypted-file
#     Init encrypted DB and add a file; verifies stored assets have PSEN header.
#   export-encrypted-file
#     Init encrypted DB, add file, export by asset ID; verifies exported file is plain (no PSEN).
#   verify-encrypted-db
#     Init encrypted DB, add file, run verify with key; checks verify succeeds.
#   delete-encrypted-file
#     Init encrypted DB, add file, remove asset by ID; verifies DB still verifies after delete.
#   list-encrypted-files
#     Init encrypted DB, add file, run list with key; verifies list output includes the added filename.
#   replicate-decrypted-from-encrypted
#     Same as replicate-from-encrypted: encrypted source -> plain destination; verifies plain replica.
#   export-with-multiple-keys
#     Two assets encrypted with different keys (key1 official, asset2 with key2); export with key1,key2; verify exports match originals.
#   multi-key-encrypt
#     Same as above; also verify list shows encryption details; export both with key1,key2; verify content matches originals.
#   partial-encrypt
#     Two assets in encrypted DB: one encrypted, one plain (--store-plain); list shows both states; export both with key; verify match originals.
#
ENCRYPTED_TESTS=(
    "init-encrypted"
    "init-generate-key-file"
    "init-generate-key-file"
    "replicate-to-encrypted"
    "replicate-from-encrypted"
    "encrypt-plain"
    "encrypt-generate-key-file"
    "encrypt-generate-key-file"
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
    "multi-key-encrypt"
    "partial-encrypt"
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

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_test_header() {
    local name="$1"
    local desc
    desc="$(get_test_description "$name")"
    echo ""
    echo "============================================================================"
    echo "Encrypted Smoke Test: $name"
    if [ -n "$desc" ]; then
        echo "  $desc"
    fi
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

# Return one-line description for a test name (for help output).
get_test_description() {
    case "$1" in
        init-encrypted) echo "Create DB with encryption and generated key" ;;
        init-generate-key-file) echo "Init encrypted DB and ensure key file is created and cleaned up" ;;
        replicate-to-encrypted) echo "Replicate plain DB to encrypted destination" ;;
        replicate-from-encrypted) echo "Replicate encrypted DB to plain destination" ;;
        encrypt-plain) echo "Encrypt plain DB in place with psi encrypt" ;;
        encrypt-generate-key-file) echo "Encrypt plain DB with generated key and ensure key file is created and cleaned up" ;;
        encrypt-reencrypt) echo "Re-encrypt DB with new key (key rotation)" ;;
        encrypt-old-to-new-format) echo "Encrypt in place with same key (format conversion, no-op)" ;;
        decrypt-encrypted) echo "Decrypt encrypted DB in place" ;;
        add-encrypted-file) echo "Add file to encrypted DB" ;;
        export-encrypted-file) echo "Export asset from encrypted DB (decrypted output)" ;;
        verify-encrypted-db) echo "Verify encrypted DB with key" ;;
        delete-encrypted-file) echo "Remove asset from encrypted DB" ;;
        list-encrypted-files) echo "List files in encrypted DB" ;;
        replicate-decrypted-from-encrypted) echo "Replicate encrypted to plain (decrypted replica)" ;;
        export-with-multiple-keys) echo "Export with both keys; verify exports match originals" ;;
        multi-key-encrypt) echo "Two assets with different keys; list shows encryption; export both; verify match originals" ;;
        partial-encrypt) echo "One encrypted, one plain asset; list shows both; export with key; verify match originals" ;;
        *) echo "" ;;
    esac
}

check_tools() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=./check-tools.sh
    source "$script_dir/check-tools.sh"
    run_check_tools
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
    local key_name="init-enc-key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key_name\" --generate-key --yes" || {
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

test_init_generate_key_file() {
    local name="init-generate-key-file"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/db"
    local key_name="init-gen-key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database with generated vault key" "$cli init --db \"$db_dir\" --key \"$key_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    if [ ! -f "$db_dir/.db/encryption.pub" ]; then
        log_error "Expected encryption.pub not found after init with generated key"
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
    local dest_key_name="rep-to-enc-dest"

    prepare_test_dir "$test_dir"

    invoke_command "Init plain source database" "$cli init --db \"$src_dir\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to plain database" "$cli add --db \"$src_dir\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Replicate to encrypted destination" "$cli replicate --db \"$src_dir\" --dest \"$dest_dir\" --dest-key \"$dest_key_name\" --generate-key --yes" || {
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

    invoke_command "Verify encrypted destination database" "$cli verify --db \"$dest_dir\" --key \"$dest_key_name\" --yes" || {
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
    local key_name="rep-from-enc-key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted source database" "$cli init --db \"$enc_dir\" --key \"$key_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$enc_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$enc_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Replicate from encrypted to plain destination" "$cli replicate --db \"$enc_dir\" --dest \"$plain_dir\" --key \"$key_name\" --yes" || {
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
    local key_name="enc-plain-key"

    prepare_test_dir "$test_dir"

    invoke_command "Init plain source database" "$cli init --db \"$plain_dir\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to plain database" "$cli add --db \"$plain_dir\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Encrypt plain database in place using psi encrypt" "$cli encrypt --db \"$plain_dir\" --key \"$key_name\" --generate-key --yes" || {
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

    invoke_command "Verify encrypted database" "$cli verify --db \"$plain_dir\" --key \"$key_name\" --yes" || {
        test_failed "$name"
        return
    }

    test_passed "$name"
}

test_encrypt_generate_key_file() {
    local name="encrypt-generate-key-file"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local plain_dir="$test_dir/plain-db"
    local key_name="enc-gen-key"

    prepare_test_dir "$test_dir"

    invoke_command "Init plain source database" "$cli init --db \"$plain_dir\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to plain database" "$cli add --db \"$plain_dir\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Encrypt plain database with generated vault key" "$cli encrypt --db \"$plain_dir\" --key \"$key_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    if [ ! -f "$plain_dir/.db/encryption.pub" ]; then
        log_error "Expected encryption.pub not found after encrypt with generated key"
        test_failed "$name"
        return
    fi

    test_passed "$name"
}

test_encrypt_reencrypt() {
    local name="encrypt-reencrypt"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local enc1_dir="$test_dir/encrypted-db-1"
    local key1_name="reenc-key1"
    local key2_name="reenc-key2"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database with key1" "$cli init --db \"$enc1_dir\" --key \"$key1_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file with key1" "$cli add --db \"$enc1_dir\" --key \"$key1_name\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$enc1_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Re-encrypt database in place with key2" "$cli encrypt --db \"$enc1_dir\" --key \"$key2_name,$key1_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$enc1_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify re-encrypted database with key2" "$cli verify --db \"$enc1_dir\" --key \"$key2_name\" --yes" || {
        test_failed "$name"
        return
    }

    # Sanity check: trying to verify with key1 should fail.
    local output
    output=$(eval "$cli verify --db \"$enc1_dir\" --key \"$key1_name\" --yes" 2>&1)
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
    local key_name="enc-fmt-key"

    prepare_test_dir "$test_dir"

    # Encrypt with same key as source: CLI exits early (no rewrite). Database
    # remains encrypted and verifies with that key.

    invoke_command "Init encrypted database (simulated old-format source)" "$cli init --db \"$old_dir\" --key \"$key_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to simulated old-format database" "$cli add --db \"$old_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Run psi encrypt in place to convert to new format" "$cli encrypt --db \"$old_dir\" --key \"$key_name\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$old_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify converted encrypted database" "$cli verify --db \"$old_dir\" --key \"$key_name\" --yes" || {
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
    local key_name="decrypt-key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$enc_dir\" --key \"$key_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$enc_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$enc_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Decrypt encrypted database in place" "$cli decrypt --db \"$enc_dir\" --key \"$key_name\" --yes" || {
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
    local key_name="add-enc-key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$db_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes" || {
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
    local key_name="export-enc-key"

    prepare_test_dir "$test_dir"
    mkdir -p "$export_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$db_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    local asset_id
    asset_id=$(get_asset_id_for_filename "$db_dir" "$key_name" "test.png") || {
        test_failed "$name"
        return
    }

    local export_path="$export_dir/exported.png"
    invoke_command "Export encrypted asset" "$cli export --db \"$db_dir\" --key \"$key_name\" \"$asset_id\" \"$export_path\" --yes" || {
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
    local key_name="verify-enc-key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$db_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$db_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify encrypted database" "$cli verify --db \"$db_dir\" --key \"$key_name\" --yes" || {
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
    local key_name="delete-enc-key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$db_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    local asset_id
    asset_id=$(get_asset_id_for_filename "$db_dir" "$key_name" "test.png") || {
        test_failed "$name"
        return
    }

    invoke_command "Remove asset from encrypted database" "$cli remove --db \"$db_dir\" --key \"$key_name\" \"$asset_id\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify encrypted database after delete" "$cli verify --db \"$db_dir\" --key \"$key_name\" --yes" || {
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
    local key_name="list-enc-key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$db_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$db_dir" || {
        test_failed "$name"
        return
    }

    local list_output
    list_output=$(invoke_command "List files in encrypted database" "$cli list --db \"$db_dir\" --key \"$key_name\" --yes") || {
        test_failed "$name"
        return
    }

    if ! echo "$list_output" | grep -q "test.png"; then
        log_error "List output does not reference added asset"
        echo "$list_output"
        test_failed "$name"
        return
    fi

    if ! echo "$list_output" | grep -q "Encryption:"; then
        log_error "List output does not contain Encryption field"
        echo "$list_output"
        test_failed "$name"
        return
    fi

    if ! echo "$list_output" | grep -q "encrypted (key:"; then
        log_error "List output does not show encrypted status with key hash"
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
    local key_name="rep-dec-key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$enc_dir\" --key \"$key_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$enc_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$enc_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Replicate from encrypted to plain destination" "$cli replicate --db \"$enc_dir\" --dest \"$plain_dir\" --key \"$key_name\" --yes" || {
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
    local key1_name="multi-exp-key1"
    local key2_name="multi-exp-key2"

    prepare_test_dir "$test_dir"
    mkdir -p "$export_dir"

    # Create encrypted database with key1 (official key).
    invoke_command "Init encrypted database with key1" "$cli init --db \"$db_dir\" --key \"$key1_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    # Ensure key2 exists (generate via throwaway database).
    invoke_command "Generate key2" "$cli init --db \"$test_dir/tmp-key2-db\" --key \"$key2_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    # Add first file with key1 (encrypted with key1).
    invoke_command "Add first PNG with key1" "$cli add --db \"$db_dir\" --key \"$key1_name\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    # Add second file with key2,key1 so key2 is write key (encrypted with key2).
    invoke_command "Add second JPG with key2" "$cli add --db \"$db_dir\" --key \"$key2_name,$key1_name\" \"$TEST_FILES_DIR/test.jpg\" --yes" || {
        test_failed "$name"
        return
    }

    # Look up asset IDs via list.
    local asset_id1
    local multi_keys="$key1_name,$key2_name"
    asset_id1=$(get_asset_id_for_filename "$db_dir" "$multi_keys" "test.png") || {
        test_failed "$name"
        return
    }

    local asset_id2
    asset_id2=$(get_asset_id_for_filename "$db_dir" "$multi_keys" "test.jpg") || {
        test_failed "$name"
        return
    }

    local export1="$export_dir/export1.png"
    local export2="$export_dir/export2.jpg"

    invoke_command "Export first asset with both keys" "$cli export --db \"$db_dir\" --key \"$multi_keys\" \"$asset_id1\" \"$export1\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Export second asset with both keys" "$cli export --db \"$db_dir\" --key \"$multi_keys\" \"$asset_id2\" \"$export2\" --yes" || {
        test_failed "$name"
        return
    }

    if [ ! -f "$export1" ] || [ ! -f "$export2" ]; then
        log_error "Expected exported files not found in $export_dir"
        test_failed "$name"
        return
    fi

    if ! cmp -s "$TEST_FILES_DIR/test.png" "$export1"; then
        log_error "Exported PNG does not match original"
        test_failed "$name"
        return
    fi

    if ! cmp -s "$TEST_FILES_DIR/test.jpg" "$export2"; then
        log_error "Exported JPG does not match original"
        test_failed "$name"
        return
    fi

    test_passed "$name"
}

test_multi_key_encrypt() {
    local name="multi-key-encrypt"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db1_dir="$test_dir/encrypted-db1"
    local db2_dir="$test_dir/encrypted-db2"
    local export_dir="$test_dir/export"
    local key1_name="multi-enc-key1"
    local key2_name="multi-enc-key2"

    prepare_test_dir "$test_dir"
    mkdir -p "$export_dir"

    # Create two encrypted DBs with different keys, add two assets to each.
    invoke_command "Init encrypted database 1 with key1" "$cli init --db \"$db1_dir\" --key \"$key1_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Init encrypted database 2 with key2" "$cli init --db \"$db2_dir\" --key \"$key2_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG and JPG to DB1 (key1)" "$cli add --db \"$db1_dir\" --key \"$key1_name\" \"$TEST_FILES_DIR/test.png\" \"$TEST_FILES_DIR/test.jpg\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG and JPG to DB2 (key2)" "$cli add --db \"$db2_dir\" --key \"$key2_name\" \"$TEST_FILES_DIR/test.png\" \"$TEST_FILES_DIR/test.jpg\" --yes" || {
        test_failed "$name"
        return
    }

    # Simulate failed re-encrypt: take one asset from DB2 (key2) and overwrite same slot in DB1. Now DB1 has one asset with key1, one with key2.
    local asset_id_jpg_db1 asset_id_jpg_db2
    asset_id_jpg_db1=$(get_asset_id_for_filename "$db1_dir" "$key1_name" "test.jpg") || { test_failed "$name"; return; }
    asset_id_jpg_db2=$(get_asset_id_for_filename "$db2_dir" "$key2_name" "test.jpg") || { test_failed "$name"; return; }

    log_info "Overwriting DB1 asset $asset_id_jpg_db1 with DB2 file (key2) to simulate partial re-encrypt"
    cp "$db2_dir/asset/$asset_id_jpg_db2" "$db1_dir/asset/$asset_id_jpg_db1" || {
        log_error "Failed to copy asset from DB2 to DB1"
        test_failed "$name"
        return
    }

    rm -rf "$db2_dir"

    # Export from DB1 with both keys; PNG is key1, JPG is key2.
    local asset_id_png
    asset_id_png=$(get_asset_id_for_filename "$db1_dir" "$key1_name,$key2_name" "test.png") || { test_failed "$name"; return; }
    asset_id_jpg_db1=$(get_asset_id_for_filename "$db1_dir" "$key1_name,$key2_name" "test.jpg") || { test_failed "$name"; return; }

    local multi_keys="$key1_name,$key2_name"
    local export1="$export_dir/out1.png"
    local export2="$export_dir/out2.jpg"
    invoke_command "Export PNG (key1)" "$cli export --db \"$db1_dir\" --key \"$multi_keys\" \"$asset_id_png\" \"$export1\" --yes" || { test_failed "$name"; return; }
    invoke_command "Export JPG (key2)" "$cli export --db \"$db1_dir\" --key \"$multi_keys\" \"$asset_id_jpg_db1\" \"$export2\" --yes" || { test_failed "$name"; return; }

    if ! cmp -s "$TEST_FILES_DIR/test.png" "$export1"; then
        log_error "Exported PNG does not match original"
        test_failed "$name"
        return
    fi
    if ! cmp -s "$TEST_FILES_DIR/test.jpg" "$export2"; then
        log_error "Exported JPG does not match original"
        test_failed "$name"
        return
    fi

    test_passed "$name"
}

test_partial_encrypt() {
    local name="partial-encrypt"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/encrypted-db"
    local export_dir="$test_dir/export"
    local key_name="partial-enc-key"

    prepare_test_dir "$test_dir"
    mkdir -p "$export_dir"

    # Create encrypted DB and add two assets (both encrypted).
    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG (encrypted)" "$cli add --db \"$db_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add JPG (encrypted)" "$cli add --db \"$db_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.jpg\" --yes" || {
        test_failed "$name"
        return
    }

    # Simulate failed encrypt: replace second asset file with plain content (one encrypted, one plain).
    local asset_id2
    asset_id2=$(get_asset_id_for_filename "$db_dir" "$key_name" "test.jpg") || { test_failed "$name"; return; }
    if [ ! -d "$db_dir/asset" ]; then
        log_error "Expected asset directory $db_dir/asset"
        test_failed "$name"
        return
    fi
    log_info "Overwriting asset $asset_id2 with plain file (simulate partial encrypt failure)"
    cp "$TEST_FILES_DIR/test.jpg" "$db_dir/asset/$asset_id2" || {
        log_error "Failed to overwrite asset with plain file"
        test_failed "$name"
        return
    }

    local asset_id1
    asset_id1=$(get_asset_id_for_filename "$db_dir" "$key_name" "test.png") || { test_failed "$name"; return; }

    local export1="$export_dir/out.png"
    local export2="$export_dir/out.jpg"
    invoke_command "Export PNG (encrypted)" "$cli export --db \"$db_dir\" --key \"$key_name\" \"$asset_id1\" \"$export1\" --yes" || { test_failed "$name"; return; }
    invoke_command "Export JPG (plain)" "$cli export --db \"$db_dir\" --key \"$key_name\" \"$asset_id2\" \"$export2\" --yes" || { test_failed "$name"; return; }

    if ! cmp -s "$TEST_FILES_DIR/test.png" "$export1"; then
        log_error "Exported PNG does not match original"
        test_failed "$name"
        return
    fi
    if ! cmp -s "$TEST_FILES_DIR/test.jpg" "$export2"; then
        log_error "Exported JPG does not match original"
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
        init-generate-key-file)            test_init_generate_key_file ;;
        replicate-to-encrypted)            test_replicate_to_encrypted ;;
        replicate-from-encrypted)          test_replicate_from_encrypted ;;
        encrypt-plain)                     test_encrypt_plain ;;
        encrypt-generate-key-file)         test_encrypt_generate_key_file ;;
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
        multi-key-encrypt)                test_multi_key_encrypt ;;
        partial-encrypt)                 test_partial_encrypt ;;
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

    if [ $TESTS_FAILED -ne 0 ]; then
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
        local desc
        desc="$(get_test_description "$name")"
        if [ -n "$desc" ]; then
            echo "  $name"
            echo "    $desc"
        else
            echo "  - $name"
        fi
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
            exit 0
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

