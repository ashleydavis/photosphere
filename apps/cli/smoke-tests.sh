#!/bin/bash

# Photosphere CLI Smoke Tests
# Based on test plan from photosphere-wiki/Test-plan-from-repo.md
# This script runs smoke tests to verify basic CLI functionality

# Absolute path to this script's directory, resolved before any cd takes place.
SMOKE_TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Set NODE_ENV to testing for deterministic UUID generation
export NODE_ENV=testing

# Disable colors for consistent output parsing
export NO_COLOR=1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
# Override TEST_TMP_DIR to run tests in parallel (e.g. TEST_TMP_DIR=./test/tmp-$$ ./smoke-tests.sh)
TEST_TMP_DIR="${TEST_TMP_DIR:-./test/tmp}"
TEST_DB_DIR="$TEST_TMP_DIR/shared/test-db"
TEST_FILES_DIR="../../test"
MULTIPLE_IMAGES_DIR="../../test/multiple-images"
DUPLICATE_IMAGES_DIR="../../test/duplicate-images"

# Isolate the vault and config so tests don't pollute the user's real data.
export PHOTOSPHERE_VAULT_DIR="${TEST_TMP_DIR}/vault"
export PHOTOSPHERE_CONFIG_DIR="${TEST_TMP_DIR}/config"
export PHOTOSPHERE_VAULT_TYPE="plaintext"

# Use built binary instead of bun run start (set by --binary)
USE_BINARY=false

# Execution mode: "parallel" (default) or "sequential"
EXECUTION_MODE=parallel

# Batch size for parallel execution (default 5)
PARALLEL_N=5

# ============================================================================
# Test Table Definition
# ============================================================================
# This table defines all tests in order. Tests are automatically numbered
# by their position in this array (starting from 1).
# Format: "name:function:description"
# ============================================================================
declare -a TEST_TABLE=(
    "create-database:test_create_database:Create new database"
    "view-media:test_view_media_files:View local media files"
    "add-png:test_add_png_file:Add PNG file to database"
    "add-jpg:test_add_jpg_file:Add JPG file to database"
    "add-mp4:test_add_mp4_file:Add MP4 file to database"
    "add-same:test_add_same_file:Add same file again (no duplication)"
    "add-multiple:test_add_multiple_files:Add multiple files"
    "add-same-multiple:test_add_same_multiple_files:Add same multiple files again"
    "add-duplicate-images:test_add_duplicate_images:Import directory with duplicate content (dedupe to 1 asset)"
    "summary:test_database_summary:Display database summary"
    "list:test_database_list:List files in database"
    "export:test_export_assets:Export assets by ID"
    "verify:test_database_verify:Verify database integrity"
    "verify-full:test_database_verify_full:Verify database integrity (full mode)"
    "detect-deleted:test_detect_deleted_file:Detect deleted file with verify"
    "detect-modified:test_detect_modified_file:Detect modified file with verify"
    "replicate:test_database_replicate:Replicate database to new location"
    "verify-replica:test_verify_replica:Verify replica integrity and match with source"
    "replicate-second:test_database_replicate_second:Second replication (no changes)"
    "compare:test_database_compare:Compare two databases"
    "compare-changes:test_compare_with_changes:Compare databases after adding changes"
    "replicate-changes:test_replicate_after_changes:Replicate changes and verify sync"
    "no-overwrite:test_cannot_create_over_existing:Cannot create database over existing"
    "repair-ok:test_repair_ok_database:Repair OK database (no changes)"
    "remove:test_remove_asset:Remove asset by ID from database"
    "repair-damaged:test_repair_damaged_database:Repair damaged database from replica"
    "v2-readonly:test_v2_database_readonly_commands:Test summary and verify reject v2 database (suggest upgrade)"
    "v2-write-fail:test_v2_database_write_commands_fail:Test write commands fail on v2 database (add, remove)"
    "v2-upgrade:test_v2_database_upgrade:Upgrade v2 database to v6"
    "v3-upgrade:test_v3_database_upgrade:Upgrade v3 database to v6"
    "v4-upgrade:test_v4_database_upgrade:Upgrade v4 database to v6"
    "v5-upgrade:test_v5_database_upgrade:Upgrade v5 database to v6"
    "v6-upgrade-no-effect:test_v6_database_upgrade_no_effect:Test v6 upgrade has no effect"
    "v6-add-file:test_v6_database_add_file:Test adding file to v6 database"
    "sync-original-to-copy:test_sync_original_to_copy:Test sync from original to copy"
    "sync-copy-to-original:test_sync_copy_to_original:Test sync from copy to original"
    "sync-edit-field:test_sync_edit_field:Test sync after editing field with bdb-cli"
    "sync-edit-field-reverse:test_sync_edit_field_reverse:Test sync after editing field in copy database with bdb-cli"
    "sync-delete-asset:test_sync_delete_asset:Test sync after deleting asset (both ways)"
    "sync-delete-asset-reverse:test_sync_delete_asset_reverse:Test sync after deleting asset from copy (reverse)"
    "replicate-deleted-asset:test_replicate_with_deleted_asset:Test replicate database with deleted asset"
    "replicate-unrelated-fail:test_replicate_unrelated_databases_fail:Test replicate fails between unrelated databases"
    "replicate-partial:test_replicate_partial:Test partial replication (README and .db files only, no media)"
    "vault-list-shared:test_vault_list_shared:Seed shared secrets in vault and verify vault list"
    "dbs-list-empty:test_dbs_list_empty:psi dbs list with no databases shows empty message"
    "dbs-add-and-list:test_dbs_add_and_list:Seed database entry and verify psi dbs list"
    "dbs-view:test_dbs_view:psi dbs view shows name path and secret IDs"
    "dbs-remove:test_dbs_remove:psi dbs remove --yes removes entry from list"
    "dbs-resolve-by-name:test_dbs_resolve_by_name:Resolve database by name with auto-resolved encryption key"
    "dbs-resolve-by-path:test_dbs_resolve_by_path:Resolve database by path with auto-resolved encryption key"
    "dbs-no-match-fallback:test_dbs_no_match_fallback:No databases.json match falls back to existing flow"
    "plaintext-vault-list-empty:test_plaintext_vault_list_empty:Empty plaintext vault shows No secrets message"
    "plaintext-vault-add:test_plaintext_vault_add:Add a secret to plaintext vault and verify with list"
    "plaintext-vault-view:test_plaintext_vault_view:View a plaintext vault secret with --yes and verify output"
    "plaintext-vault-edit:test_plaintext_vault_edit:Edit a plaintext vault secret with --yes and verify updated value"
    "plaintext-vault-delete:test_plaintext_vault_delete:Delete a plaintext vault secret with --yes and verify removal"
    "secrets-import:test_secrets_import:Import a PEM key pair and verify via list"
    "keychain-vault-list-empty:test_keychain_vault_list_empty:Keychain vault list command succeeds"
    "keychain-vault-add:test_keychain_vault_add:Add a secret to OS keychain and verify it appears in list"
    "keychain-vault-view:test_keychain_vault_view:Add a secret to OS keychain and verify secrets view returns correct value"
    "keychain-vault-edit:test_keychain_vault_edit:Add a secret to OS keychain, edit its value, verify updated value"
    "keychain-vault-delete:test_keychain_vault_delete:Add a secret to OS keychain, delete it, verify it is gone from list"
    "keychain-vault-list-multiple:test_keychain_vault_list_multiple:Add multiple secrets to OS keychain and verify all appear in list"
    "dbs-edit:test_dbs_edit:Edit a database entry with --yes and verify rename"
    "dbs-add-cli:test_dbs_add_cli:Add a database via CLI with --yes and verify"
    "dbs-add-duplicate:test_dbs_add_duplicate:Adding a database with a duplicate name fails with error"
    "secrets-add-duplicate:test_secrets_add_duplicate:Adding a secret with a duplicate name fails with error"
    "dbs-clear:test_dbs_clear:psi dbs clear --yes removes all database entries from the list"
    "secrets-clear:test_secrets_clear:psi secrets clear --yes removes all secrets from the vault"
)

# Test table helper functions
# Get test directory path for a given test number
get_test_dir() {
    local test_number="$1"
    echo "$TEST_TMP_DIR/$test_number"
}

# Get test name by index (1-based)
get_test_name() {
    local index=$1
    if [ "$index" -ge 1 ] && [ "$index" -le "${#TEST_TABLE[@]}" ]; then
        echo "${TEST_TABLE[$((index-1))]}" | cut -d: -f1
    fi
}

# Get test function by index (1-based)
get_test_function() {
    local index=$1
    if [ "$index" -ge 1 ] && [ "$index" -le "${#TEST_TABLE[@]}" ]; then
        echo "${TEST_TABLE[$((index-1))]}" | cut -d: -f2
    fi
}

# Get test description by index (1-based)
get_test_description() {
    local index=$1
    if [ "$index" -ge 1 ] && [ "$index" -le "${#TEST_TABLE[@]}" ]; then
        echo "${TEST_TABLE[$((index-1))]}" | cut -d: -f3-
    fi
}

# Get test index by name (returns 1-based index, or 0 if not found)
get_test_index_by_name() {
    local name=$1
    local index=1
    for test_entry in "${TEST_TABLE[@]}"; do
        local test_name=$(echo "$test_entry" | cut -d: -f1)
        if [ "$test_name" = "$name" ]; then
            echo "$index"
            return 0
        fi
        index=$((index + 1))
    done
    echo "0"
    return 1
}

# Get test function by name
get_test_function_by_name() {
    local name=$1
    for test_entry in "${TEST_TABLE[@]}"; do
        local test_name=$(echo "$test_entry" | cut -d: -f1)
        if [ "$test_name" = "$name" ]; then
            echo "$test_entry" | cut -d: -f2
            return 0
        fi
    done
    return 1
}

# Get total number of tests
get_test_count() {
    echo "${#TEST_TABLE[@]}"
}

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# Trap to show summary on exit (including failures)
cleanup_and_show_summary() {
    local exit_code=$?
    echo ""
    echo "============================================================================"
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓✓✓ ALL SMOKE TESTS PASSED ✓✓✓${NC}"
    else
        echo -e "${RED}✗✗✗ SMOKE TESTS FAILED ✗✗✗${NC}"
    fi
    echo "============================================================================"

    exit $exit_code
}

trap cleanup_and_show_summary EXIT

# Helper functions shared with check-tools.sh
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

# Get CLI command: default is from code (bun run start --); use --binary for built executable
get_cli_command() {
    if [ "$USE_BINARY" = "true" ]; then
        local platform=$(detect_platform)
        local arch=$(detect_architecture)
        case "$platform" in
            "linux")
                echo "./bin/x64/linux/psi"
                ;;
            "mac")
                if [ "$arch" = "arm64" ]; then
                    echo "./bin/arm64/mac/psi"
                else
                    echo "./bin/x64/mac/psi"
                fi
                ;;
            "win")
                echo "./bin/x64/win/psi.exe"
                ;;
            *)
                echo "./bin/x64/linux/psi"  # Default to linux
                ;;
        esac
    else
        echo "bun run start --"
    fi
}

# Detect platform and set build command
detect_platform() {
    case "$(uname -s)" in
        Linux*)     echo "linux";;
        Darwin*)    echo "mac";;
        CYGWIN*|MINGW*|MSYS*) echo "win";;
        *)          echo "linux";;  # Default to linux
    esac
}

# Detect architecture
detect_architecture() {
    case "$(uname -m)" in
        x86_64|amd64)    echo "x64";;
        arm64|aarch64)   echo "arm64";;
        *)               echo "x64";;  # Default to x64
    esac
}

# Unified command invocation (needed by test_setup and check_tools)
invoke_command() {
    local description="$1"
    local command="$2"
    local expected_exit_code="${3:-0}"
    local output_var_name="${4:-}"

    log_info "Running: $description"
    echo ""
    echo -e "${YELLOW}NODE_ENV:${NC} ${NODE_ENV:-'(not set)'}"
    echo -e "${YELLOW}Command:${NC}"
    echo -e "${BLUE}$command${NC}"
    echo ""

    local command_output=""
    local actual_exit_code=0

    local env_prefix="NODE_ENV=testing "
    local full_command="$env_prefix$command"

    if [ -n "$output_var_name" ]; then
        command_output=$(eval "$full_command" 2>&1)
        actual_exit_code=$?
        echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
        echo "$command_output"
        echo "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"
        eval "$output_var_name=\"\$command_output\""
    else
        echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
        eval "$full_command"
        actual_exit_code=$?
        echo "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"
    fi

    if [ $actual_exit_code -eq $expected_exit_code ]; then
        if [ $expected_exit_code -eq 0 ]; then
            log_success "$description"
        else
            log_success "$description (expected failure with exit code $actual_exit_code)"
        fi
        return 0
    else
        if [ $expected_exit_code -eq 0 ]; then
            log_error "$description (exit code: $actual_exit_code)"
        else
            log_error "$description (expected failure but command succeeded)"
        fi
        exit 1
    fi
}

# Individual test functions (remain inline — not tests, just setup)
test_setup() {
    local platform=$(detect_platform)
    local arch=$(detect_architecture)
    log_info "Detected platform: $platform"
    log_info "Detected architecture: $arch"

    log_info "Changing to CLI directory"
    if ! cd "$(dirname "$0")"; then
        log_error "Failed to change to CLI directory"
        return 1
    fi

    local cli_command=$(get_cli_command)
    log_info "Using CLI command: $cli_command"

    log_info "Cleaning up previous test run"
    rm -rf "$TEST_TMP_DIR"

    # Ensure tmp directory exists
    mkdir -p "$TEST_TMP_DIR"

    log_info "Building CLI executable for platform: $platform ($arch)"
    case "$platform" in
        "linux")
            invoke_command "Build Linux executable" "bun run build-linux"
            ;;
        "mac")
            if [ "$arch" = "arm64" ]; then
                invoke_command "Build macOS ARM64 executable" "bun run build-mac-arm64"
            else
                invoke_command "Build macOS x64 executable" "bun run build-mac-x64"
            fi
            ;;
        "win")
            invoke_command "Build Windows executable" "bun run build-win"
            ;;
    esac

    log_info "Building mk CLI executable for platform: $platform ($arch)"
    cd ../mk-cli
    case "$platform" in
        "linux")
            invoke_command "Build mk Linux executable" "bun run build-linux"
            ;;
        "mac")
            if [ "$arch" = "arm64" ]; then
                invoke_command "Build mk macOS ARM64 executable" "bun run build-mac-arm64"
            else
                invoke_command "Build mk macOS x64 executable" "bun run build-mac-x64"
            fi
            ;;
        "win")
            invoke_command "Build mk Windows executable" "bun run build-win"
            ;;
    esac
    cd ../cli

    log_info "Building bdb CLI executable for platform: $platform ($arch)"
    cd ../bdb-cli
    case "$platform" in
        "linux")
            invoke_command "Build bdb Linux executable" "bun run build-linux"
            ;;
        "mac")
            if [ "$arch" = "arm64" ]; then
                invoke_command "Build bdb macOS ARM64 executable" "bun run build-mac-arm64"
            else
                invoke_command "Build bdb macOS x64 executable" "bun run build-mac-x64"
            fi
            ;;
        "win")
            invoke_command "Build bdb Windows executable" "bun run build-win"
            ;;
    esac
    cd ../cli

    TESTS_PASSED=$((TESTS_PASSED + 1))
}

check_tools() {
    # shellcheck source=./check-tools.sh
    source "$SMOKE_TESTS_DIR/check-tools.sh"
    run_check_tools
}

# Reset function to clean up test artifacts
reset_environment() {
    echo "======================================"
    echo "Photosphere CLI Smoke Tests - RESET"
    echo "======================================"
    
    log_info "Changing to CLI directory"
    if ! cd "$(dirname "$0")"; then
        log_error "Failed to change to CLI directory"
        return 1
    fi
    
    log_info "Current directory: $(pwd)"
    log_info "Cleaning up test artifacts..."
    
    # Reset UUID counter for deterministic test results
    local UUID_COUNTER_FILE="$TEST_TMP_DIR/photosphere-test-uuid-counter"
    if [ -f "$UUID_COUNTER_FILE" ]; then
        log_info "Resetting test UUID counter"
        rm -f "$UUID_COUNTER_FILE"
        log_success "Removed UUID counter file"
    else
        log_info "UUID counter file not found (already clean)"
    fi
    
    # Remove the specific test database directory
    if [ -d "$TEST_TMP_DIR" ]; then
        log_info "Removing all test databases: $TEST_TMP_DIR"
        rm -rf "$TEST_TMP_DIR"
        log_success "Removed $TEST_TMP_DIR"
    else
        log_info "Test tmp directory not found (already clean): $TEST_TMP_DIR"
    fi
    
    # Remove the replicated database directory
    local replica_dir="$TEST_DB_DIR-replica"
    if [ -d "$replica_dir" ]; then
        log_info "Removing replicated database: $replica_dir"
        rm -rf "$replica_dir"
        log_success "Removed $replica_dir"
    else
        log_info "Replicated database directory not found (already clean): $replica_dir"
    fi
    
    log_success "Environment reset complete!"
    echo ""
    log_info "You can now run tests with a clean environment:"
    log_info "  $0 all              # Run all tests"
    log_info "  $0 setup            # Run just setup"
    log_info "  $0 create-database  # Run specific test"
}

# Extract the numeric prefix from a test script path (e.g. smoke-tests/27-v2-readonly/test.sh -> 27)
test_number() {
    local test_sh="$1"
    basename "$(dirname "$test_sh")" | grep -oE '^[0-9]+'
}

# Extract the name portion from a test script path (e.g. smoke-tests/27-v2-readonly/test.sh -> v2-readonly)
test_name() {
    local test_sh="$1"
    basename "$(dirname "$test_sh")" | sed 's/^[0-9]*-//'
}

# Run a single test script sequentially; redirect all script output to its log file.
run_one() {
    local test_sh="$1"
    local dir num name log_file dir_name
    dir="$(dirname "$test_sh")"
    num="$(test_number "$test_sh")"
    name="$(test_name "$test_sh")"
    log_file="$dir/tmp/test-run.log"
    dir_name="$(basename "$dir")"
    mkdir -p "$dir/tmp"
    if [ "$dir_name" != "01-core" ]; then
        export ISOLATED_TEST_TMP_DIR="${TEST_TMP_DIR}/${dir_name}"
    else
        unset ISOLATED_TEST_TMP_DIR
    fi
    printf "${BLUE}RUN ${NC}  %2s  %s\n" "$num" "$name"
    if timeout 300 bash "$test_sh" >"$log_file" 2>&1; then
        printf "${GREEN}PASS${NC}  %2s  %s\n" "$num" "$name"
        return 0
    else
        printf "${RED}FAIL${NC}  %2s  %s  (log: %s)\n" "$num" "$name" "$log_file"
        return 1
    fi
}

# Run each script one at a time with run_one; accumulate counts and call print_summary.
run_sequential() {
    local pass=0
    local fail=0
    for test_sh in "$@"; do
        if run_one "$test_sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    done
    print_summary "$pass" "$fail"
    return $((fail > 0 ? 1 : 0))
}

# Run scripts in parallel batches of N; accumulate counts and call print_summary.
run_parallel() {
    local parallel_n="$1"
    shift
    local tests=("$@")
    local pass=0
    local fail=0
    local total="${#tests[@]}"
    local i=0

    while ((i < total)); do
        local batch_tests=()
        local batch_pids=()
        local j=0
        while ((j < parallel_n && i < total)); do
            batch_tests+=("${tests[i]}")
            i=$((i + 1))
            j=$((j + 1))
        done

        for test_sh in "${batch_tests[@]}"; do
            local dir log_file num name dir_name
            dir="$(dirname "$test_sh")"
            num="$(test_number "$test_sh")"
            name="$(test_name "$test_sh")"
            dir_name="$(basename "$dir")"
            log_file="$dir/tmp/test-run.log"
            mkdir -p "$dir/tmp"
            printf "${BLUE}RUN ${NC}  %2s  %s\n" "$num" "$name"
            ISOLATED_TEST_TMP_DIR="${TEST_TMP_DIR}/${dir_name}" timeout 300 bash "$test_sh" >"$log_file" 2>&1 &
            batch_pids+=($!)
        done

        local k=0
        for pid in "${batch_pids[@]}"; do
            local test_sh num name
            test_sh="${batch_tests[$k]}"
            num="$(test_number "$test_sh")"
            name="$(test_name "$test_sh")"
            if wait "$pid"; then
                printf "${GREEN}PASS${NC}  %2s  %s\n" "$num" "$name"
                pass=$((pass + 1))
            else
                printf "${RED}FAIL${NC}  %2s  %s  (log: %s/tmp/test-run.log)\n" "$num" "$name" "$(dirname "$test_sh")"
                fail=$((fail + 1))
            fi
            k=$((k + 1))
        done
    done

    print_summary "$pass" "$fail"
    return $((fail > 0 ? 1 : 0))
}

# Print final pass/fail summary banner.
print_summary() {
    local pass="$1"
    local fail="$2"
    local total=$((pass + fail))
    echo ""
    if ((fail == 0)); then
        printf "${GREEN}All %d tests passed${NC}\n" "$total"
    else
        printf "${RED}%d of %d tests failed${NC}\n" "$fail" "$total"
    fi
}

# Discover all test scripts under smoke-tests/ in sorted order
discover_tests() {
    find smoke-tests -name "test.sh" | sort -V
}

# Map a test number to the script that contains it.
# Tests 1-26 -> 01-core, test 43 -> 43-replicate-partial, all others map 1:1.
get_script_for_test() {
    local test_number="$1"
    if [ "$test_number" -ge 1 ] && [ "$test_number" -le 26 ]; then
        echo "smoke-tests/01-core/test.sh"
    elif [ "$test_number" -eq 43 ]; then
        echo "smoke-tests/43-replicate-partial/test.sh"
    else
        local script
        script=$(find smoke-tests -maxdepth 2 -name "test.sh" | sort -V | grep -E "smoke-tests/${test_number}-" | head -1)
        echo "$script"
    fi
}

# Invoke a single test script, export all env vars so subprocesses inherit them.
# Records pass/fail into the orchestrator's TESTS_PASSED/TESTS_FAILED counters.
run_script() {
    local script_path="$1"
    local test_number="$2"

    export TEST_TMP_DIR TEST_DB_DIR TEST_FILES_DIR MULTIPLE_IMAGES_DIR DUPLICATE_IMAGES_DIR
    export USE_BINARY IMAGEMAGICK_IDENTIFY_CMD

    # Give non-core scripts an isolated tmp dir so parallel runs don't conflict.
    local dir_name
    dir_name=$(basename "$(dirname "$script_path")")
    if [ "$dir_name" != "01-core" ]; then
        export ISOLATED_TEST_TMP_DIR="${TEST_TMP_DIR}/${dir_name}"
    else
        unset ISOLATED_TEST_TMP_DIR
    fi

    bash "$script_path" "$test_number"
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        local test_name
        test_name=$(get_test_name "$test_number")
        FAILED_TESTS+=("$test_name")
        log_error "Script $script_path exited with code $exit_code"
        exit $exit_code
    fi
}

run_all_tests() {
    echo "======================================"
    echo "Photosphere CLI Smoke Tests"
    echo "======================================"

    log_info "Changing to CLI directory"
    cd "$(dirname "$0")"

    # Reset environment
    log_info "Resetting testing environment"
    if [ -d "$TEST_TMP_DIR" ]; then
        rm -rf "$TEST_TMP_DIR"
        log_success "Removed existing test databases"
    fi

    # Reset UUID counter
    local UUID_COUNTER_FILE="$TEST_TMP_DIR/photosphere-test-uuid-counter"
    if [ -f "$UUID_COUNTER_FILE" ]; then
        rm -f "$UUID_COUNTER_FILE"
    fi

    # Clear local cache
    log_info "Clearing local cache before running tests"
    invoke_command "Clear local cache" "$(get_cli_command) clear-cache" || {
        log_warning "Failed to clear cache, continuing anyway..."
    }

    # Check tools first
    check_tools

    # Collect all scripts (excluding keychain tests)
    local all_scripts=()
    while IFS= read -r script_path; do
        local dir_name
        dir_name=$(basename "$(dirname "$script_path")")
        if [[ "$dir_name" == *keychain* ]]; then
            continue
        fi
        all_scripts+=("$script_path")
    done < <(discover_tests)

    echo ""
    if [ "${EXECUTION_MODE:-parallel}" = "sequential" ]; then
        log_info "Running ${#all_scripts[@]} tests sequentially"
        run_sequential "${all_scripts[@]}"
    else
        log_info "Running ${#all_scripts[@]} tests in parallel (batch size ${PARALLEL_N:-5})"
        run_parallel "${PARALLEL_N:-5}" "${all_scripts[@]}"
    fi
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        exit $exit_code
    fi
    exit 0
}

# Run a specific test by name or number
run_test() {
    local test_name="$1"
    
    # Handle special commands
    case "$test_name" in
        "all")
            run_all_tests
            return
            ;;
        "reset")
            reset_environment
            return
            ;;
        "setup")
            # This is handled as a command in main(), but keeping here for completeness
            test_setup
            return
            ;;
        "check-tools")
            check_tools
            return
            ;;
    esac
    
    # Check if it's a numeric test index
    local test_number
    if [[ "$test_name" =~ ^[0-9]+$ ]]; then
        test_number="$test_name"
        if [ "$test_number" -lt 1 ] || [ "$test_number" -gt "$(get_test_count)" ]; then
            log_error "Invalid test number: $test_number (must be 1-$(get_test_count))"
            echo ""
            show_usage
            exit 1
        fi
    else
        test_number=$(get_test_index_by_name "$test_name")
        if [ "$test_number" -eq 0 ]; then
            log_error "Unknown test: $test_name"
            echo ""
            show_usage
            exit 1
        fi
    fi

    local script_path
    script_path=$(get_script_for_test "$test_number")
    if [ -z "$script_path" ] || [ ! -f "$script_path" ]; then
        log_error "No script found for test $test_number"
        exit 1
    fi

    if ! run_one "$script_path"; then
        exit 1
    fi
}

# Function to run multiple commands in sequence
run_multiple_commands() {
    local commands_string="$1"
    
    # Split commands by comma
    IFS=',' read -ra COMMANDS <<< "$commands_string"
    
    echo "======================================"
    echo "Photosphere CLI Smoke Tests - MULTIPLE"
    echo "======================================"
    log_info "Running ${#COMMANDS[@]} commands in sequence: $commands_string"
    echo ""
    
    # Clear local cache before running tests
    log_info "Clearing local cache before running tests"
    invoke_command "Clear local cache" "$(get_cli_command) clear-cache" || {
        log_warning "Failed to clear cache, continuing anyway..."
    }
    
    
    # Check tools first before running any tests
    check_tools
    
    
    local command_number=1
    local total_commands=${#COMMANDS[@]}
    
    for command in "${COMMANDS[@]}"; do
        # Trim whitespace
        command=$(echo "$command" | xargs)
        
        echo ""
        echo "--- Command $command_number/$total_commands: $command ---"

        run_test "$command"
        
        # If we get here, the command succeeded (otherwise it would have exited)
        log_success "Completed command $command_number/$total_commands: $command"
        command_number=$((command_number + 1))
    done
    
    # Show final summary - we only get here if all commands succeeded
    echo ""
    echo "======================================"
    echo "MULTIPLE COMMANDS SUMMARY"
    echo "======================================"
    echo -e "Commands run: ${BLUE}$total_commands${NC}"
    echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
    echo ""
    echo -e "${GREEN}ALL COMMANDS COMPLETED SUCCESSFULLY${NC}"
    
    # Always preserve database for inspection
    echo ""
    log_info "Database preserved for inspection at: $TEST_DB_DIR"
    log_info "To clean up when done: $0 reset"
    
    exit 0
}

# Show usage information
show_usage() {
    echo "Usage: $0 [options] <command|test-name> [command2,command3,...]"
    echo "       $0 [options] to <test-number>"
    echo ""
    echo "Run Photosphere CLI smoke tests"
    echo ""
    echo "Options:"
    echo "  -b, --binary          - Run tests using the built executable (default: run from code with 'bun run start --')"
    echo "  -t, --tmp-dir <dir>   - Use <dir> for test databases (default: ./test/tmp)."
    echo "  --sequential          - Run independent tests sequentially instead of in parallel"
    echo "  --parallel [N]        - Run independent tests in parallel with batch size N (default: 5)"
    echo "  -h, --help            - Show this help message"
    echo ""
    echo "Commands:"
    echo "  all                 - Run all tests (default if no command given)"
    local test_count=$(get_test_count)
    echo "  to <number>         - Run tests 1 through <number> (1-$test_count)"
    echo "  setup               - Build executable"
    echo "  check-tools         - Check required media processing tools are available"
    echo "  reset               - Clean up test artifacts and reset environment"
    echo "  help                - Show this help message"
    echo ""
    echo "Individual tests:"
    # Generate test list from test table
    local index=1
    for test_entry in "${TEST_TABLE[@]}"; do
        local test_name=$(echo "$test_entry" | cut -d: -f1)
        local test_description=$(echo "$test_entry" | cut -d: -f3-)
        printf "  %-25s (%d) - %s\n" "$test_name" "$index" "$test_description"
        index=$((index + 1))
    done
    echo ""
    echo "Multiple commands:"
    echo "  Use commas to separate commands (no spaces around commas)"
    echo ""
    echo "Examples:"
    echo "  $0                            # Run all tests in parallel (default)"
    echo "  $0 all                        # Run all tests in parallel"
    echo "  $0 --sequential               # Run all tests sequentially"
    echo "  $0 --parallel 3              # Run in parallel with batch size 3"
    echo "  $0 --parallel 10             # Run in parallel with batch size 10"
    echo "  $0 --binary                  # Run all tests using built executable"
    echo "  $0 to 5                      # Run tests 1-5"
    echo "  $0 setup,all                # Build and run all tests (tools must be available)"
    echo "  $0 setup,check-tools,all    # Build, check tools, and run all tests"
    echo "  $0 setup                     # Build executable only"
    echo "  $0 check-tools               # Check tools only"
    echo "  $0 reset                     # Clean up test artifacts"
    echo "  $0 create-database          # Run only database creation test"
    echo "  $0 3                         # Run test 3 (add single file)"
    echo "  $0 27                        # Run test 27 (v2-readonly) independently"
    echo "  $0 help                      # Show this help"
}

# Main test execution
main() {
    # Parse command line options from entire argument list (options can appear before or after test names)
    POSITIONAL=()
    while [[ $# -gt 0 ]]; do
        case $1 in
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
                TEST_DB_DIR="$TEST_TMP_DIR/shared/test-db"
                shift 2
                ;;
            --tmp-dir=*)
                TEST_TMP_DIR="${1#*=}"
                TEST_DB_DIR="$TEST_TMP_DIR/shared/test-db"
                shift
                ;;
            --sequential)
                EXECUTION_MODE=sequential
                shift
                ;;
            --parallel)
                EXECUTION_MODE=parallel
                if [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
                    PARALLEL_N="$2"
                    shift
                fi
                shift
                ;;
            -h|--help|help)
                show_usage
                exit 0
                ;;
            *)
                POSITIONAL+=("$1")
                shift
                ;;
        esac
    done
    set -- "${POSITIONAL[@]}"
    
    # Check for help request
    if [ $# -eq 1 ] && [ "$1" = "help" ]; then
        show_usage
        exit 0
    fi
    
    # Default to "all" if no command given
    if [ $# -eq 0 ]; then
        set -- "all"
    fi
    
    # Show binary mode status if enabled
    if [ "$USE_BINARY" = "true" ]; then
        log_info "Using built executable for smoke tests"
    fi

    # Handle "to X" command
    if [ "$1" = "to" ] && [ $# -eq 2 ]; then
        local end_test="$2"
        local max_test=$(get_test_count)
        if [[ "$end_test" =~ ^[0-9]+$ ]] && [ "$end_test" -ge 1 ] && [ "$end_test" -le "$max_test" ]; then
            cd "$(dirname "$0")"
            log_info "Running tests 1 through $end_test"
            log_info "Resetting testing environment"
            if [ -d "$TEST_TMP_DIR" ]; then
                rm -rf "$TEST_TMP_DIR"
                log_success "Removed existing test databases"
            fi

            local UUID_COUNTER_FILE="$TEST_TMP_DIR/photosphere-test-uuid-counter"
            if [ -f "$UUID_COUNTER_FILE" ]; then
                rm -f "$UUID_COUNTER_FILE"
            fi

            log_info "Clearing local cache before running tests"
            invoke_command "Clear local cache" "$(get_cli_command) clear-cache" || {
                log_warning "Failed to clear cache, continuing anyway..."
            }

            check_tools

            # Always run 01-core first (tests 1-26).
            echo ""
            echo "--- Running 01-core (tests 1-26) ---"
            unset ISOLATED_TEST_TMP_DIR
            if ! run_one "smoke-tests/01-core/test.sh"; then
                exit 1
            fi

            # Run individual scripts for tests 27–end_test sequentially.
            if [ "$end_test" -gt 26 ]; then
                local indep_scripts=()
                declare -A seen_indep
                for ((i=27; i<=end_test; i++)); do
                    local script
                    script=$(get_script_for_test "$i")
                    if [ -n "$script" ] && [ -z "${seen_indep[$script]:-}" ]; then
                        seen_indep["$script"]=1
                        indep_scripts+=("$script")
                    fi
                done
                if [ ${#indep_scripts[@]} -gt 0 ]; then
                    if ! run_sequential "${indep_scripts[@]}"; then
                        exit 1
                    fi
                fi
            fi

            exit 0
        else
            log_error "Invalid test number: $end_test (must be 1-$max_test)"
            show_usage
            exit 1
        fi
    fi
    
    # Check if multiple commands are provided (contains comma)
    if [[ "$1" == *","* ]]; then
        run_multiple_commands "$1"
        return
    fi
    
    # Check if running all tests
    if [ "$1" = "all" ]; then
        run_all_tests
        return
    fi
    
    # Check if running reset command
    if [ "$1" = "reset" ]; then
        reset_environment
        exit 0
    fi
    
    # Check if running setup command
    if [ "$1" = "setup" ]; then
        test_setup
        exit 0
    fi
    
    # Check if running check-tools command
    if [ "$1" = "check-tools" ]; then
        check_tools
        exit 0
    fi
    
    # Running individual test
    echo "======================================"
    echo "Photosphere CLI Smoke Tests"
    echo "======================================"
    
    log_info "Running specific test: $1"
    
    # Clear local cache before running tests
    log_info "Clearing local cache before running tests"
    invoke_command "Clear local cache" "$(get_cli_command) clear-cache" || {
        log_warning "Failed to clear cache, continuing anyway..."
    }
    
    
    # Check tools first before running individual test
    check_tools
    
    run_test "$1"
    
    # If we get here, test passed
    echo ""
    echo "======================================"
    echo "INDIVIDUAL TEST SUMMARY"
    echo "======================================"
    echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
    echo ""
    echo -e "${GREEN}TEST PASSED${NC}"
    
    exit 0
}

# Run main function
main "$@"
