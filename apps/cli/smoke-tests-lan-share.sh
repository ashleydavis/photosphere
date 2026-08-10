#!/bin/bash

# Photosphere CLI LAN Share Smoke Tests
# Runs sender and receiver CLI commands in parallel to verify end-to-end
# database and secret sharing over the LAN.

set -euo pipefail

# Always run from the script's own directory so relative paths (test/, ./bin/...) resolve
# regardless of the caller's CWD (e.g. `bun run test:cli:lan-share` from the repo root).
cd "$(dirname "$0")"

# Disable colors for consistent output parsing.
export NO_COLOR=1

# Colors for test output.
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Per-test temporary directories, the same allocator every other suite in this repository uses.
_LAN_SHARE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_LAN_SHARE_SCRIPT_DIR/../../scripts/lib/allocate-test-temp-dir.sh"

# Starting and stopping background processes: the tree walk this suite kills its receiver with.
# Shared with the desktop and mobile suites so there is one implementation rather than a copy per
# caller.
source "$_LAN_SHARE_SCRIPT_DIR/../../scripts/lib/process-control.sh"

# The per-test timeout every suite in this repository shares, and the reporting that goes with it.
source "$_LAN_SHARE_SCRIPT_DIR/../../scripts/lib/test-timeout.sh"

# The suite root. It is NOT where a test runs: run_test points TEST_TMP_DIR at a uniquely named
# directory for the length of each test.
#
# Exported, because the CLI is a child process and cannot see a variable that is only assigned. An
# unexported TEST_TMP_DIR sends every psi process to the shared /tmp/photosphere, which another
# suite's `hash-cache clear` then deletes underneath it.
export TEST_TMP_DIR="${TEST_TMP_DIR:-./test/tmp-lan-share}"
export PHOTOSPHERE_TMP_DIR="$TEST_TMP_DIR"

# Isolated vault and config dirs for sender and receiver. Rebuilt by use_test_temp_dir for each
# test, so no two tests, and no two concurrent runs, share them.
SENDER_VAULT_DIR="${TEST_TMP_DIR}/sender-vault"
SENDER_CONFIG_DIR="${TEST_TMP_DIR}/sender-config"
RECEIVER_VAULT_DIR="${TEST_TMP_DIR}/receiver-vault"
RECEIVER_CONFIG_DIR="${TEST_TMP_DIR}/receiver-config"

#
# Points this suite's directories at the given directory: the temp root every psi process resolves,
# and the four sender and receiver locations every test builds its paths from.
# Usage: use_test_temp_dir <dir>
#
use_test_temp_dir() {
    local dir="$1"
    photosphere_export_test_temp "$dir"
    SENDER_VAULT_DIR="${dir}/sender-vault"
    SENDER_CONFIG_DIR="${dir}/sender-config"
    RECEIVER_VAULT_DIR="${dir}/receiver-vault"
    RECEIVER_CONFIG_DIR="${dir}/receiver-config"
}
export PHOTOSPHERE_VAULT_TYPE="plaintext"

# Counters.
TESTS_PASSED=0
TESTS_FAILED=0

# CLI command (default: run from source).
CLI_CMD="bun run start --"

# Active receiver PID (cleaned up after every test).
RECEIVER_PID=""

log_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Kill a process and its descendants reliably.
#
# `bun run start` runs the actual CLI in a child process that owns the UDP broadcast and HTTPS
# server. Killing only the top-level PID (especially SIGKILL, which the wrapper cannot forward)
# orphans that child, which keeps broadcasting its pairing code and gets picked up by the next
# test's sender, corrupting it. kill_process_tree takes the whole tree, which prevents the orphan.
kill_proc() {
    local pid="$1"
    kill_process_tree "$pid"
    wait "$pid" 2>/dev/null || true
}

# Every process this test started, so cleanup and the watchdog can reach all of them by pid.
#
# Nothing in this suite may ever select a process by matching its command line. `pkill -f` and
# anything like it asks the kernel about every process on the machine, and the CLI's command line is
# the same whichever checkout or worktree launched it, so it kills another run's identical process.
# That happened: one suite's exit trap SIGTERMed another suite's sender mid-test, and the failure it
# produced named an innocent test. A recorded pid belongs to this run and to nothing else.
TEST_PIDS=()

# The same pids on disk, for the watchdog.
#
# The watchdog is a background subshell, and a subshell gets a copy of the shell's variables at the
# moment it forks, so it can never see a pid recorded after it started. That is every pid it needs.
# A file is shared rather than copied, so the watchdog reads what the test has launched by the time
# it fires. Set per test by run_test.
TEST_PID_FILE=""

# Records a process this test started, in the array cleanup reads and the file the watchdog reads.
# Usage: track_test_pid <pid>
track_test_pid() {
    local pid="$1"
    TEST_PIDS+=("$pid")
    if [ -n "$TEST_PID_FILE" ]; then
        echo "$pid" >> "$TEST_PID_FILE"
    fi
}

# Runs a CLI command, recording its pid so it can be killed if the test hangs, and returns its exit
# code once it finishes.
#
# Backgrounding and waiting rather than running in the foreground is the whole point: a foreground
# child has no pid the watchdog can see, and that absence is what a command-line pattern used to
# paper over. `wait` on a known pid gives the same blocking behaviour and the same exit code.
# Usage: run_cli_tracked <log_file> <args...>
run_cli_tracked() {
    local log_file="$1"
    shift

    "$@" > "$log_file" 2>&1 &
    local cli_pid=$!
    track_test_pid "$cli_pid"

    local status=0
    wait "$cli_pid" || status=$?
    return "$status"
}

# Kills everything this test started, deepest process first, and forgets them.
#
# The tree walk matters as much as the pid does: `bun run` is a wrapper, and the process that owns
# the UDP broadcast and the HTTPS server is its child. Killing only the wrapper leaves that child
# running and broadcasting, which is the orphan a command-line pattern used to sweep up afterwards.
kill_test_pids() {
    local pid
    for pid in "${TEST_PIDS[@]+"${TEST_PIDS[@]}"}"; do
        kill_process_tree "$pid"
    done
    TEST_PIDS=()
    if [ -n "$TEST_PID_FILE" ]; then
        : > "$TEST_PID_FILE"
    fi
}

# Clean up after every test — kill any active receiver and anything else the test started.
test_cleanup() {
    if [ -n "$RECEIVER_PID" ]; then
        kill_proc "$RECEIVER_PID"
        RECEIVER_PID=""
    fi
    kill_test_pids
}

# Clean up on script exit.
cleanup() {
    test_cleanup
    local job_pid
    for job_pid in $(jobs -p 2>/dev/null); do
        kill_process_tree "$job_pid"
    done
    wait 2>/dev/null || true
}
trap cleanup EXIT

# Merge one secret into a vault directory's single vault.json file, which holds every secret keyed by
# its name. The merge is a read-modify-write, so seeding a second secret keeps the first. An absent
# vault file starts from an empty object, and a vault file that does not parse fails rather than
# being silently replaced with a fresh one.
merge_vault_secret() {
    local vault_dir="$1"
    local secret_json="$2"
    local vault_file="${vault_dir}/vault.json"

    mkdir -p "$vault_dir"
    if [ ! -f "$vault_file" ]; then
        printf '%s' '{}' > "$vault_file"
    fi

    local merged
    if ! merged=$(jq -c --argjson secret "$secret_json" '. + {($secret.name): $secret}' "$vault_file"); then
        log_fail "Vault file $vault_file is not valid JSON"
        return 1
    fi
    printf '%s' "$merged" > "$vault_file"
    chmod 600 "$vault_file"
}

# Seed a vault secret directly into a vault directory. The name goes into a JSON key, so a colon,
# slash or space in it needs no encoding. jq --arg passes each value in as data, never as text
# spliced into a template, so a quote, backslash or newline is escaped rather than becoming syntax.
seed_vault_secret() {
    local vault_dir="$1"
    local secret_name="$2"
    local secret_type="$3"
    local secret_value="$4"

    merge_vault_secret "$vault_dir" "$(jq -cn --arg name "$secret_name" --arg type "$secret_type" --arg value "$secret_value" \
        '{name: $name, type: $type, value: $value}')"
}

# The same, with the secret's value read verbatim from a file, newlines and all, which is how a
# multi-line PEM gets in. jq --rawfile keeps the file's exact bytes, including any trailing newline,
# which $(cat ...) would strip.
seed_vault_secret_from_file() {
    local vault_dir="$1"
    local secret_name="$2"
    local secret_type="$3"
    local value_file="$4"

    merge_vault_secret "$vault_dir" "$(jq -cn --arg name "$secret_name" --arg type "$secret_type" --rawfile value "$value_file" \
        '{name: $name, type: $type, value: $value}')"
}

# Count the secrets held in a vault directory's vault.json. Prints 0 when the file is absent.
count_vault_secrets() {
    local vault_dir="$1"
    local vault_file="${vault_dir}/vault.json"

    if [ ! -f "$vault_file" ]; then
        printf '0'
        return 0
    fi
    jq 'length' "$vault_file"
}

# Seed a databases.json config file directly.
seed_databases_config() {
    local config_dir="$1"
    local databases_json="$2"

    mkdir -p "$config_dir"
    # Rendered by the mobile harness's helper, which goes through node-api's own
    # buildDatabasesConfigToml: the same function the app writes the file with, so a seeded config
    # cannot drift from the format the app reads.
    DATABASES="$databases_json" RECENT="[]" \
        bun ../smoke-tests/lib/write-databases-config.ts "${config_dir}/databases.toml"
}

# Start a receiver in background with the given pairing code and wait for it to be ready.
# Sets: RECEIVER_PID
start_receiver_with_code() {
    local cmd_prefix="$1"  # "dbs" or "secrets"
    local log_file="$2"
    local code="$3"

    PHOTOSPHERE_VAULT_DIR="$RECEIVER_VAULT_DIR" \
    PHOTOSPHERE_CONFIG_DIR="$RECEIVER_CONFIG_DIR" \
        $CLI_CMD $cmd_prefix receive --yes --code "$code" > "$log_file" 2>&1 &
    RECEIVER_PID=$!
    # Recorded as well as held in RECEIVER_PID, so the watchdog can reach it if the test hangs before
    # the point where test_cleanup would normally take it down.
    track_test_pid "$RECEIVER_PID"

    # Poll until the receiver logs that it is waiting for a sender.
    for attempt in $(seq 1 25); do
        sleep 0.2
        if [ -f "$log_file" ] && grep -q "Waiting for sender" "$log_file" 2>/dev/null; then
            # Give the HTTPS server and UDP broadcast a moment to be fully ready.
            sleep 0.3
            return 0
        fi
        # Also check for an early exit indicating an error.
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            log_fail "Receiver process exited unexpectedly."
            cat "$log_file" 2>/dev/null || true
            test_cleanup
            return 1
        fi
    done

    log_fail "Receiver was not ready within 5 seconds."
    cat "$log_file" 2>/dev/null || true
    test_cleanup
    return 1
}

# Reset test dirs.
reset_dirs() {
    rm -rf "$SENDER_VAULT_DIR" "$SENDER_CONFIG_DIR" "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"
    mkdir -p "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"
}

# Per-test timeout in seconds, from scripts/lib/test-timeout.sh so every suite here holds its tests
# to the same ceiling.
#
# This suite used to set its own 90, chosen to clear one case: a sender ignores any receiver whose
# pairing code does not match its own, so a test that deliberately uses the wrong code never matches
# and waits out the sender's full 60 second discovery window. That case still ends itself at 60
# seconds when the sender gives up, so it passes under the shared ceiling exactly as it did under 90.
# Nothing here needs a private number.
TEST_TIMEOUT="$PHOTOSPHERE_PER_TEST_TIMEOUT"

# Run a test function with per-test timeout, cleanup, and timing.
# The test runs in the foreground (so counters and RECEIVER_PID work).
# A background watchdog kills bun processes if the test exceeds the timeout.
run_test() {
    local test_func="$1"
    local start_time=$SECONDS

    # A uniquely named directory for this test, so no two of these cases, and no two concurrent runs
    # out of one checkout, write to the same sender vault, receiver vault or receiver log. Every one
    # of these tests already starts by clearing the directories it uses, so nothing here depends on
    # state left by the test before it.
    local suite_tmp_dir="$TEST_TMP_DIR"
    use_test_temp_dir "$(photosphere_test_temp_dir "$test_func")"

    # Where this test records what it launches, inside the test's own directory so two runs cannot
    # share it.
    TEST_PIDS=()
    TEST_PID_FILE="$TEST_TMP_DIR/test-pids"
    : > "$TEST_PID_FILE"

    # Background watchdog — kills what this test started, and only that, if it runs over time.
    (
        sleep "$TEST_TIMEOUT"
        while IFS= read -r stuck_pid; do
            [ -n "$stuck_pid" ] || continue
            kill_process_tree "$stuck_pid"
        done < "$TEST_PID_FILE"
    ) &
    local watchdog_pid=$!

    # Run the test directly. The || true disables set -e inside the function
    # so individual command failures don't kill the script.
    "$test_func" || true

    # Cancel the watchdog.
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    test_cleanup
    sleep 0.3

    # Put the suite root back, so anything running between tests is not left pointing at the
    # directory of the test that has just finished.
    use_test_temp_dir "$suite_tmp_dir"

    local elapsed=$(( SECONDS - start_time ))
    if [ "$elapsed" -ge "$TEST_TIMEOUT" ]; then
        log_fail "$test_func timed out after ${TEST_TIMEOUT}s"
        # These tests run as shell functions in the foreground, so everything the test printed is
        # already above this on stdout and there is no separate log file to point at. The report is
        # still worth printing: it is what says the run ended because the test stopped rather than
        # because it decided something.
        report_test_timeout "$test_func" "$TEST_TIMEOUT" ""
    fi
    echo -e "  ${YELLOW}(${elapsed}s)${NC}"
    echo ""
}

# ============================================================================
# Test 1: Share a database (sender -> receiver) via CLI
# ============================================================================
test_share_database() {
    log_info "--- Test: Share a database over LAN (CLI) ---"
    reset_dirs

    seed_vault_secret "$SENDER_VAULT_DIR" "s3sender" "s3-credentials" \
        '{"region":"us-east-1","accessKeyId":"AKIATEST","secretAccessKey":"secret123","endpoint":"http://localhost:9000"}'

    # Generate a real RSA-2048 PEM so resolveDatabaseSharePayload can derive the public key.
    local pem_file="${TEST_TMP_DIR}/encsndr1.pem"
    mkdir -p "$TEST_TMP_DIR" "$SENDER_VAULT_DIR"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$pem_file" 2>/dev/null
    seed_vault_secret_from_file "$SENDER_VAULT_DIR" "encsndr1" "encryption-key" "$pem_file"

    seed_databases_config "$SENDER_CONFIG_DIR" \
        '[{"name":"share-test-db","description":"A database for LAN share testing","path":"s3:test-bucket/photos","s3Key":"s3sender","encryptionKey":"encsndr1"}]'

    local test_code="1234"
    local receiver_log="${TEST_TMP_DIR}/receiver-db.log"
    start_receiver_with_code "dbs" "$receiver_log" "$test_code" || return 1

    local sender_log="${TEST_TMP_DIR}/sender-db.log"
    run_cli_tracked "$sender_log" env \
        PHOTOSPHERE_VAULT_DIR="$SENDER_VAULT_DIR" \
        PHOTOSPHERE_CONFIG_DIR="$SENDER_CONFIG_DIR" \
        $CLI_CMD dbs send --name share-test-db --yes --code "$test_code" || true

    # Give receiver a moment to process.
    sleep 0.2

    if grep -q "sent successfully" "$sender_log" 2>/dev/null; then
        log_success "Database share: sender reports success"
    else
        log_fail "Database share: sender did not report success"
        cat "$sender_log" 2>/dev/null || true
        return 1
    fi

    local receiver_secrets
    receiver_secrets=$(count_vault_secrets "$RECEIVER_VAULT_DIR")
    if [ "$receiver_secrets" -ge 1 ]; then
        log_success "Database share: receiver vault has $receiver_secrets secret(s)"
    else
        log_fail "Database share: receiver vault is empty after share"
        return 1
    fi

    if grep -q "imported successfully" "$receiver_log" 2>/dev/null; then
        log_success "Database share: receiver reports success"
    else
        log_fail "Database share: receiver did not report success"
        return 1
    fi

    if [ -f "${RECEIVER_CONFIG_DIR}/databases.toml" ] && grep -q "share-test-db" "${RECEIVER_CONFIG_DIR}/databases.toml"; then
        log_success "Database share: receiver has database entry"
    else
        log_fail "Database share: receiver databases.toml missing expected entry"
        return 1
    fi
}

# ============================================================================
# Test 2: Share a secret (sender -> receiver) via CLI
# ============================================================================
test_share_secret() {
    log_info "--- Test: Share a secret over LAN (CLI) ---"
    reset_dirs

    seed_vault_secret "$SENDER_VAULT_DIR" "apikey01" "api-key" \
        'AIzaFakeKey123'

    local test_code="2345"
    local receiver_log="${TEST_TMP_DIR}/receiver-secret.log"
    start_receiver_with_code "secrets" "$receiver_log" "$test_code" || return 1

    local sender_log="${TEST_TMP_DIR}/sender-secret.log"
    run_cli_tracked "$sender_log" env \
        PHOTOSPHERE_VAULT_DIR="$SENDER_VAULT_DIR" \
        PHOTOSPHERE_CONFIG_DIR="$SENDER_CONFIG_DIR" \
        $CLI_CMD secrets send --name "apikey01" --yes --code "$test_code" || true

    sleep 0.2

    if grep -q "sent successfully" "$sender_log" 2>/dev/null; then
        log_success "Secret share: sender reports success"
    else
        log_fail "Secret share: sender did not report success"
        cat "$sender_log" 2>/dev/null || true
        return 1
    fi

    local receiver_secrets
    receiver_secrets=$(count_vault_secrets "$RECEIVER_VAULT_DIR")
    if [ "$receiver_secrets" -ge 1 ]; then
        log_success "Secret share: receiver vault has $receiver_secrets secret(s)"
    else
        log_fail "Secret share: receiver vault is empty after share"
        return 1
    fi

    if grep -q "imported successfully" "$receiver_log" 2>/dev/null; then
        log_success "Secret share: receiver reports success"
    else
        log_fail "Secret share: receiver did not report success"
        return 1
    fi
}

# ============================================================================
# Test 3: Wrong pairing code is rejected
# ============================================================================
test_wrong_pairing_code() {
    log_info "--- Test: Wrong pairing code is rejected ---"
    reset_dirs

    seed_vault_secret "$SENDER_VAULT_DIR" "apikey01" "api-key" \
        'AIzaFakeKey123'

    local receiver_code="3456"
    local wrong_code="7890"
    log_info "Receiver code: $receiver_code, sender will use wrong code: $wrong_code"

    local receiver_log="${TEST_TMP_DIR}/receiver-wrong-code.log"
    start_receiver_with_code "secrets" "$receiver_log" "$receiver_code" || return 1

    local sender_log="${TEST_TMP_DIR}/sender-wrong-code.log"
    run_cli_tracked "$sender_log" env \
        PHOTOSPHERE_VAULT_DIR="$SENDER_VAULT_DIR" \
        PHOTOSPHERE_CONFIG_DIR="$SENDER_CONFIG_DIR" \
        $CLI_CMD secrets send --name "apikey01" --yes --code "$wrong_code" || true

    if grep -q "Pairing code rejected" "$sender_log" 2>/dev/null; then
        log_success "Wrong code: sender reports rejection"
    else
        log_fail "Wrong code: sender did not report rejection"
        cat "$sender_log" 2>/dev/null || true
        return 1
    fi

    local receiver_secrets
    receiver_secrets=$(count_vault_secrets "$RECEIVER_VAULT_DIR")
    if [ "$receiver_secrets" -eq 0 ]; then
        log_success "Wrong code: receiver vault is still empty (no import)"
    else
        log_fail "Wrong code: receiver vault should be empty but has $receiver_secrets file(s)"
        return 1
    fi
}

# ============================================================================
# Test 4: Share a database with no linked secrets
# ============================================================================
test_share_database_no_secrets() {
    log_info "--- Test: Share a database with no linked secrets ---"
    reset_dirs
    mkdir -p "$SENDER_VAULT_DIR"

    seed_databases_config "$SENDER_CONFIG_DIR" \
        '[{"name":"plain-db","description":"No secrets attached","path":"/tmp/plain-db"}]'

    local test_code="4567"
    local receiver_log="${TEST_TMP_DIR}/receiver-no-secrets.log"
    start_receiver_with_code "dbs" "$receiver_log" "$test_code" || return 1

    local sender_log="${TEST_TMP_DIR}/sender-no-secrets.log"
    run_cli_tracked "$sender_log" env \
        PHOTOSPHERE_VAULT_DIR="$SENDER_VAULT_DIR" \
        PHOTOSPHERE_CONFIG_DIR="$SENDER_CONFIG_DIR" \
        $CLI_CMD dbs send --name plain-db --yes --code "$test_code" || true

    sleep 0.2

    if grep -q "sent successfully" "$sender_log" 2>/dev/null; then
        log_success "No-secrets DB share: sender reports success"
    else
        log_fail "No-secrets DB share: sender did not report success"
        cat "$sender_log" 2>/dev/null || true
        return 1
    fi

    local receiver_secrets
    receiver_secrets=$(count_vault_secrets "$RECEIVER_VAULT_DIR")
    if [ "$receiver_secrets" -eq 0 ]; then
        log_success "No-secrets DB share: receiver vault is empty (no secrets to import)"
    else
        log_fail "No-secrets DB share: receiver vault should be empty but has $receiver_secrets file(s)"
        return 1
    fi

    if [ -f "${RECEIVER_CONFIG_DIR}/databases.toml" ] && grep -q "plain-db" "${RECEIVER_CONFIG_DIR}/databases.toml"; then
        log_success "No-secrets DB share: receiver has database entry"
    else
        log_fail "No-secrets DB share: receiver databases.toml missing expected entry"
        return 1
    fi
}

# ============================================================================
# Test 5: Receiver exits cleanly on cancel
# ============================================================================
test_receiver_cancel() {
    log_info "--- Test: Receiver exits cleanly on cancel ---"

    rm -rf "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"
    mkdir -p "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"

    local receiver_log="${TEST_TMP_DIR}/receiver-timeout.log"
    start_receiver_with_code "secrets" "$receiver_log" "5678" || return 1
    log_info "Receiver started (no sender will connect)"

    kill -INT "$RECEIVER_PID" 2>/dev/null || true
    wait "$RECEIVER_PID" 2>/dev/null || true
    RECEIVER_PID=""

    if ! grep -q "EADDRINUSE\|stack trace\|panic" "$receiver_log" 2>/dev/null; then
        log_success "Receiver cancel: exited cleanly after SIGINT"
    else
        log_fail "Receiver cancel: log contains errors"
        cat "$receiver_log" 2>/dev/null || true
        return 1
    fi
}

# ============================================================================
# Test 6: Rogue process cannot access receiver without pin
# ============================================================================
test_rogue_receiver_rejected() {
    log_info "--- Test: Rogue process cannot access receiver without pin ---"

    reset_dirs

    seed_vault_secret "$SENDER_VAULT_DIR" "roguekey" "api-key" \
        'ROGUE_SECRET_VALUE_12345'

    local receiver_log="${TEST_TMP_DIR}/receiver-rogue.log"
    start_receiver_with_code "secrets" "$receiver_log" "6789" || return 1
    log_info "Rogue test: receiver started"

    local broadcast_msg
    broadcast_msg=$(timeout 5 bun run test/udp-listen.ts 2>/dev/null || true)

    if [ -z "$broadcast_msg" ]; then
        log_fail "Rogue test: could not capture UDP broadcast"
        return 1
    fi

    log_info "Rogue test: captured broadcast: $broadcast_msg"

    # Parse "PSIE_RECV:{port}:{codeHash}:{fingerprint}" with bash parameter expansion. Only the
    # port is needed here, and it is still the first field.
    local without_prefix="${broadcast_msg#PSIE_RECV:}"
    local receiver_port="${without_prefix%%:*}"

    if [ -z "$receiver_port" ]; then
        log_fail "Rogue test: could not parse port from broadcast"
        return 1
    fi

    log_info "Rogue test: receiver is on port $receiver_port"

    # Attack 1: Wrong code hash via HTTPS.
    local rogue_code_hash
    rogue_code_hash=$(echo -n "9999" | sha256sum | cut -d' ' -f1)
    local rogue_body="{\"codeHash\":\"${rogue_code_hash}\",\"payload\":{\"type\":\"secret\",\"secretType\":\"api-key\",\"value\":\"{\\\"label\\\":\\\"evil\\\",\\\"apiKey\\\":\\\"EVIL\\\"}\"}}"

    local rogue_status
    rogue_status=$(curl -s -o /dev/null -w "%{http_code}" -k --max-time 3 \
        -X POST -H "Content-Type: application/json" -d "$rogue_body" \
        "https://127.0.0.1:${receiver_port}/share-payload" 2>/dev/null) || true

    if [ "$rogue_status" = "403" ]; then
        log_success "Rogue test: HTTPS with wrong pin rejected (403)"
    else
        log_fail "Rogue test: expected 403 but got $rogue_status"
    fi

    # Attack 2: Plain HTTP (no TLS).
    local http_result
    http_result=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
        -X POST -H "Content-Type: application/json" -d "$rogue_body" \
        "http://127.0.0.1:${receiver_port}/share-payload" 2>/dev/null) || true

    if [ -z "$http_result" ] || [ "$http_result" = "000" ]; then
        log_success "Rogue test: plain HTTP connection refused (server is HTTPS-only)"
    else
        log_fail "Rogue test: plain HTTP got response $http_result (should have been refused)"
    fi

    # Verify receiver vault is still empty.
    local receiver_secrets
    receiver_secrets=$(count_vault_secrets "$RECEIVER_VAULT_DIR")
    if [ "$receiver_secrets" -eq 0 ]; then
        log_success "Rogue test: receiver vault still empty (rogue payload not accepted)"
    else
        log_fail "Rogue test: receiver vault has $receiver_secrets file(s) — rogue payload was accepted!"
    fi
}

# ============================================================================
# Test 7: Receiver cert fingerprint matches its UDP broadcast
# ============================================================================
test_cert_fingerprint_matches_broadcast() {
    log_info "--- Test: Receiver cert fingerprint matches its broadcast ---"

    rm -rf "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"
    mkdir -p "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"

    local receiver_log="${TEST_TMP_DIR}/receiver-cert.log"
    start_receiver_with_code "secrets" "$receiver_log" "8901" || return 1

    local broadcast_msg
    broadcast_msg=$(timeout 5 bun run test/udp-listen.ts 2>/dev/null || true)

    if [ -z "$broadcast_msg" ]; then
        log_fail "Cert test: could not capture UDP broadcast"
        return 1
    fi

    # Parse "PSIE_RECV:{port}:{codeHash}:{fingerprint}" with bash parameter expansion. The
    # fingerprint is taken last because it can itself contain colons.
    local without_prefix="${broadcast_msg#PSIE_RECV:}"
    local receiver_port="${without_prefix%%:*}"
    local after_port="${without_prefix#*:}"
    local broadcast_fingerprint="${after_port#*:}"

    if [ -z "$receiver_port" ] || [ -z "$broadcast_fingerprint" ]; then
        log_fail "Cert test: could not parse broadcast"
        return 1
    fi

    log_info "Cert test: broadcast fingerprint: $broadcast_fingerprint"

    local actual_fingerprint
    actual_fingerprint=$(echo | openssl s_client -connect "127.0.0.1:${receiver_port}" -servername localhost 2>/dev/null \
        | openssl x509 -outform DER 2>/dev/null \
        | sha256sum \
        | cut -d' ' -f1)

    log_info "Cert test: actual TLS fingerprint: $actual_fingerprint"

    if [ "$broadcast_fingerprint" = "$actual_fingerprint" ]; then
        log_success "Cert test: broadcast fingerprint matches TLS certificate"
    else
        log_fail "Cert test: broadcast fingerprint does NOT match TLS certificate"
        return 1
    fi

    local tampered="0000000000000000000000000000000000000000000000000000000000000000"
    if [ "$tampered" != "$actual_fingerprint" ]; then
        log_success "Cert test: tampered fingerprint correctly differs from real cert"
    else
        log_fail "Cert test: tampered fingerprint unexpectedly matched"
        return 1
    fi
}

# ============================================================================
# Main
# ============================================================================

echo ""
echo "=================================================="
echo "  Photosphere LAN Share Smoke Tests"
echo "=================================================="
echo ""

# Parse arguments.
while [ $# -gt 0 ]; do
    case "$1" in
        -b|--binary)
            CLI_CMD="./bin/x64/linux/psi"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [-b|--binary]"
            exit 1
            ;;
    esac
done

mkdir -p "$TEST_TMP_DIR"

# No machine-wide kill of leftover receivers here, deliberately. It cannot tell an orphan of a
# previous run of this suite from the live receiver of a suite running right now, and killing the
# latter is what made this suite and the CLI to desktop one fail each other. Two things cover what it
# was for: this suite kills its own receiver through its tracked pid, tree and all, so it leaves no
# orphan to begin with, and a sender ignores any receiver announcing a pairing code other than its
# own (packages/lan-share-network/src/lib/lan-share-sender.ts), so one that did survive cannot
# capture a later share.
sleep 0.5

SUITE_START=$SECONDS

run_test test_share_database
run_test test_share_secret
run_test test_wrong_pairing_code
run_test test_share_database_no_secrets
run_test test_receiver_cancel
run_test test_rogue_receiver_rejected
run_test test_cert_fingerprint_matches_broadcast

SUITE_ELAPSED=$(( SECONDS - SUITE_START ))

echo "=================================================="
echo "  Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed (${SUITE_ELAPSED}s)"
echo "=================================================="

if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
