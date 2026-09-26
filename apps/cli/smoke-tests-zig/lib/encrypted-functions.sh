#!/bin/bash

# Helpers for the Zig versions of the encrypted smoke tests in smoke-tests-encrypted.sh (left unchanged).
# Verbatim copies of that suite's environment setup and helper functions, so each test ported from it
# runs as a standalone script under smoke-tests-zig.sh. The only difference is where the test's
# temporary directory comes from: the Zig runner hands each test its own TEST_TMP_DIR, which is where
# smoke-tests-encrypted.sh's run_single_test points it for the length of one test.
# Sourced by the Zig encrypted smoke tests before lib/interop.sh.

# Ensure deterministic UUIDs and disable colors for parsing
export NODE_ENV=testing
export NO_COLOR=1

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# The test's own directory, allocated by smoke-tests-zig.sh, exported with the temp and cache
# directories under it as smoke-tests-encrypted.sh's run_single_test does.
export TEST_TMP_DIR="${TEST_TMP_DIR:-./test/tmp-zig/encrypted}"
export PHOTOSPHERE_TMP_DIR="$TEST_TMP_DIR"

# The hash caches are not temporary files: they live with the user's own data so they outlive a
# restart, so pointing the temp directory at this suite says nothing about where they go.
export PHOTOSPHERE_CACHE_DIR="$TEST_TMP_DIR/cache"
TEST_FILES_DIR="../../test"

# Isolate the vault and config so tests don't pollute the user's real data.
export PHOTOSPHERE_VAULT_DIR="${TEST_TMP_DIR}/vault"
export PHOTOSPHERE_CONFIG_DIR="${TEST_TMP_DIR}/config"
export PHOTOSPHERE_VAULT_TYPE="plaintext"

# Use the built binary instead of bun run start (set and exported by smoke-tests-zig.sh).
USE_BINARY="${USE_BINARY:-false}"

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
                if [ "$(uname -m)" = "arm64" ]; then
                    echo "./bin/arm64/mac/psi"
                else
                    echo "./bin/x64/mac/psi"
                fi
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
#
# A command that died in the Bun shutdown panic is run a second time, and only that one. Bun crashes
# on exit after a `psi verify` that has already finished its work and printed
# "Database verification passed - all files are intact", panicking with either
# "Unexpected JS error: JSError" and SIGILL or a segmentation fault, and saying itself that it
# indicates a bug in Bun rather than in the code it was running. It has failed this suite four times
# now across three of its tests, most recently `encrypt-reencrypt` in Release run 34014186020, and it
# is recorded as BUN-PANIC-ON-EXIT-AFTER-VERIFY in docs/flaky-tests-registry.md, where its cause is
# still unestablished after two attempts at it. There is nothing in this repository to fix, so the
# retry is what carries the suite past an upstream crash.
#
# It is deliberately narrow. The marker Bun prints when it panics is the only thing that triggers it,
# so an ordinary non-zero exit still fails on the first attempt exactly as it did before, and the
# retry says loudly that it happened rather than swallowing it. If the second attempt crashes the
# same way, or fails for any other reason, that is the failure the test reports.
#
# Usage: invoke_command "description" "actual command"
invoke_command() {
    local description="$1"
    local command="$2"

    log_info "$description"
    local output
    output=$(eval "$command" 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ] && [[ "$output" == *"oh no: Bun has crashed"* ]]; then
        log_error "Bun crashed on exit (exit $exit_code) running: $command"
        echo "$output"
        log_info "Bun panicked rather than the command failing, so running it once more. See BUN-PANIC-ON-EXIT-AFTER-VERIFY in docs/flaky-tests-registry.md."
        output=$(eval "$command" 2>&1)
        exit_code=$?
    fi

    if [ $exit_code -ne 0 ]; then
        log_error "Command failed (exit $exit_code): $command"
        echo "$output"
        return $exit_code
    fi

    echo "$output"
    return 0
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
