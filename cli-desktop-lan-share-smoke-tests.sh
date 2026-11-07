#!/bin/bash

#
# Photosphere CLI <-> Desktop LAN Share Smoke Tests
#
# Exercises end-to-end LAN sharing across the CLI and the Electron desktop app
# in both directions, for both secrets and databases:
#
#   1. CLI sender      -> Desktop receiver  (secret)
#   2. CLI sender      -> Desktop receiver  (database + linked secrets)
#   3. Desktop sender  -> CLI receiver      (secret)
#   4. Desktop sender  -> CLI receiver      (database + linked secrets)
#

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP_DIR="$ROOT_DIR/apps/desktop"
DESKTOP_FRONTEND_DIR="$ROOT_DIR/apps/desktop-frontend"
CLI_DIR="$ROOT_DIR/apps/cli"

# Shared helpers: start_app, wait_for_ready, wait_for_log, send_command, stop_app,
# log_info / log_success / log_error.
source "$DESKTOP_DIR/smoke-tests/lib/common.sh"

# The per-test timeout every suite in this repository shares, and the reporting that goes with it.
source "$ROOT_DIR/scripts/lib/test-timeout.sh"

# Where this run's four tests keep their vaults, configs, databases and logs. One directory per run,
# from the allocator every other shell suite here uses, whose mktemp name cannot collide with a
# second run's however close together the two start.
#
# It was `$ROOT_DIR/tmp-cli-desktop-lan-share`, the same path for every run started from this
# worktree, and the Main section below deletes and recreates it on the way in. Two runs at once
# therefore shared every file underneath it: each test's `rm -rf "$TMP_ROOT/$test_name"` deleted the
# other run's fixtures mid-test, and both desktop apps opened the one `<test>/desktop/app.log` with
# `>`, so each truncated what the other had written and the waits that read that file by line number
# read the other run's lines. Proven by running this suite against a second copy of itself
# (`bun run test:parallel -- --scripts "test:lan-share:cli-desktop"`): one side timed out waiting for
# `Secret review step` while its app.log held both apps' output interleaved, a half-written line, two
# `shutting down` lines and a FATAL from a pid that side never started. A run whose evidence has been
# rewritten by another run is also why a failure here could report one thing while the artifacts left
# behind showed another (`SECRET-SHARE-FAILED-WITH-EVERY-ARTIFACT-GREEN` in the flaky-test registry).
#
# The allocator's root is outside the repository and nothing here deletes it, so a failed run's
# evidence survives instead of being wiped by the next run's `rm -rf`.
TMP_ROOT="$(photosphere_test_temp_dir cli-desktop-lan-share)"

# Counters and bookkeeping for the suite.
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TEST_NAMES=()

# PIDs of any CLI helper processes for the current test, cleaned up between tests.
CLI_PIDS=()

# Per-test timeout (covers UDP discovery + TLS pairing + file IO).
LAN_TIMEOUT=60

#
# Kills any CLI helper processes started by the current test, ignoring missing PIDs.
#
cleanup_cli_pids() {
    local cli_pid
    for cli_pid in "${CLI_PIDS[@]+"${CLI_PIDS[@]}"}"; do
        # The tree, not just the pid. `bun run` is a wrapper and the process holding the UDP
        # broadcast and the HTTPS server is its child, so killing the wrapper alone leaves that child
        # broadcasting. That orphan is what the command-line pattern below this used to sweep up.
        kill_process_tree "$cli_pid"
        wait "$cli_pid" 2>/dev/null || true
    done
    CLI_PIDS=()
}

#
# Global cleanup on script exit — terminates any lingering CLI receivers/senders
# and any background jobs spawned by tests.
#
# No command-line matching here, deliberately. Selecting a process by what it looks like reaches
# every process on the machine, and this suite's CLI is indistinguishable from the one another
# worktree's run just started, so it used to kill that one instead. Everything this suite launches is
# recorded in CLI_PIDS or is a job of this shell, and both are reachable by pid.
#
suite_cleanup() {
    cleanup_cli_pids
    local job_pid
    for job_pid in $(jobs -p 2>/dev/null); do
        kill_process_tree "$job_pid"
    done
}
trap suite_cleanup EXIT

#
# Builds bundle/main.js and the renderer, which is what start_app points Electron at. The root
# `bun run bundle` is the one definition of that build, so this calls it rather than repeating its
# two halves here.
#
# PHOTOSPHERE_SKIP_DESKTOP_BUNDLE says the caller has already built it. scripts/test-everything-parallel.sh
# sets it after building once for the whole run, because this suite and apps/desktop/smoke-tests.sh
# write the same directories and vite empties bundle/frontend before rewriting it, so two builds at
# once can delete the renderer the other is about to launch. Unset, which is how this suite runs on
# its own, the build happens here as it always did.
#
bundle_desktop() {
    if [ -n "${PHOTOSPHERE_SKIP_DESKTOP_BUNDLE:-}" ]; then
        log_info "Bundle already built by the caller (PHOTOSPHERE_SKIP_DESKTOP_BUNDLE is set): skipping bundle step."
        return
    fi
    log_info "Bundling desktop-frontend and desktop..."
    (cd "$ROOT_DIR" && bun run bundle) > "$TMP_ROOT/bundle.log" 2>&1
}

#
# Merges one secret into a vault directory's single vault.json file, which holds every secret keyed
# by its name. The merge is a read-modify-write, so seeding a second secret keeps the first. An
# absent vault file starts from an empty object, and a vault file that does not parse fails the test
# outright rather than being silently replaced with a fresh one.
# Usage: merge_vault_secret <vault_dir> <secret_json>
#
merge_vault_secret() {
    local vault_dir="$1"
    local secret_json="$2"
    local vault_file="$vault_dir/vault.json"

    mkdir -p "$vault_dir"
    if [ ! -f "$vault_file" ]; then
        printf '%s' '{}' > "$vault_file"
    fi

    local merged
    if ! merged=$(jq -c --argjson secret "$secret_json" '. + {($secret.name): $secret}' "$vault_file"); then
        echo "Vault file $vault_file is not valid JSON" >&2
        return 1
    fi
    printf '%s' "$merged" > "$vault_file"
    chmod 600 "$vault_file"
}

#
# Returns success when a vault directory's vault.json holds a secret under the given name.
# Usage: vault_has_secret <vault_dir> <name>
#
vault_has_secret() {
    local vault_dir="$1"
    local secret_name="$2"
    local vault_file="$vault_dir/vault.json"

    if [ ! -f "$vault_file" ]; then
        return 1
    fi
    jq -e --arg name "$secret_name" 'has($name)' "$vault_file" > /dev/null
}

#
# Seeds a vault directory with a single plain-text secret. The name goes into a JSON key, so a
# colon, slash or space in it needs no encoding, and jq --arg escapes a quote, backslash or newline
# in the value as data rather than letting it become syntax.
# Usage: seed_secret <vault_dir> <name> <type> <value>
#
seed_secret() {
    local vault_dir="$1"
    local secret_name="$2"
    local secret_type="$3"
    local secret_value="$4"
    merge_vault_secret "$vault_dir" "$(jq -cn --arg name "$secret_name" --arg type "$secret_type" --arg value "$secret_value" \
        '{name: $name, type: $type, value: $value}')"
}

#
# Seeds a vault directory with an RSA-2048 encryption-key secret built from a real PEM.
# Usage: seed_encryption_key <vault_dir> <name>
#
seed_encryption_key() {
    local vault_dir="$1"
    local secret_name="$2"
    mkdir -p "$vault_dir"
    local pem_file="$vault_dir/$secret_name.pem"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$pem_file" 2>/dev/null
    # jq --rawfile reads the PEM's exact bytes (trailing newline included, which $(cat ...) would
    # strip) and --arg passes the name in as data, so nothing is spliced into a template.
    merge_vault_secret "$vault_dir" "$(jq -cn --arg name "$secret_name" --arg type encryption-key --rawfile value "$pem_file" \
        '{name: $name, type: $type, value: $value}')"
    rm -f "$pem_file"
}

#
# Writes a databases.toml config with a single database entry.
# Usage: seed_databases_toml <config_dir> <db_name> <db_path> [s3_key] [encryption_key]
#
seed_databases_toml() {
    local config_dir="$1"
    local db_name="$2"
    local db_path="$3"
    local s3_key="${4:-}"
    local encryption_key="${5:-}"
    mkdir -p "$config_dir"
    {
        echo "[[databases]]"
        echo "name = \"$db_name\""
        echo "description = \"\""
        echo "path = \"$db_path\""
        if [ -n "$s3_key" ]; then
            echo "s3_key = \"$s3_key\""
        fi
        if [ -n "$encryption_key" ]; then
            echo "encryption_key = \"$encryption_key\""
        fi
    } > "$config_dir/databases.toml"
}

#
# Polls the desktop test-control server for the pairing-code element and prints
# it once it contains a 4-digit value. Returns non-zero on timeout.
# Usage: read_desktop_pairing_code <port>
#
read_desktop_pairing_code() {
    local port="$1"
    local elapsed=0
    while [ "$elapsed" -lt 30 ]; do
        local response
        response=$(curl -sf "http://localhost:$port/get-value?dataId=share-pairing-code" 2>/dev/null || true)
        local code
        code=$(echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/')
        if [ -n "$code" ] && echo "$code" | grep -qE '^[0-9]{4}$'; then
            echo "$code"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

#
# Starts a CLI receiver in the background and records its PID for later cleanup.
# Returns once the receiver is ready (broadcasting) or has already completed.
# Usage: start_cli_receiver <subcommand> <vault_dir> <config_dir> <log_file> <code>
#   subcommand is "secrets" or "dbs".
#
start_cli_receiver() {
    local subcommand="$1"
    local vault_dir="$2"
    local config_dir="$3"
    local log_file="$4"
    local code="$5"
    (
        cd "$CLI_DIR"
        PHOTOSPHERE_VAULT_DIR="$vault_dir" \
        PHOTOSPHERE_CONFIG_DIR="$config_dir" \
        PHOTOSPHERE_VAULT_TYPE=plaintext \
            bun run start -- "$subcommand" receive --yes --code "$code"
    ) > "$log_file" 2>&1 &
    local cli_pid=$!
    CLI_PIDS+=("$cli_pid")
    # Counted in seconds, like every other wait in this file. This loop used to sleep half a second
    # per increment while comparing the count against 15, so it gave up after 7.5 seconds rather than
    # the 15 it reads as. A cold CLI start is about 230ms on this machine when nothing else is
    # running, but test:everything runs ten suites at once: under that load the receiver had not
    # printed its first line within 7.5 seconds and the test failed with "CLI receiver did not start
    # within timeout" against a receiver that was still starting normally. LAN_TIMEOUT is what the
    # rest of the suite already waits. A longer wait costs nothing when the receiver is healthy,
    # because the loop returns the moment its log line appears, and returns early if it has exited.
    local elapsed=0
    while [ "$elapsed" -lt "$LAN_TIMEOUT" ]; do
        if grep -q "Waiting for sender\|imported successfully\|Pairing code rejected" "$log_file" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$cli_pid" 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log_error "CLI receiver did not start within timeout. Log:"
    cat "$log_file" 2>/dev/null || true
    return 1
}

#
# Runs a CLI sender to completion in the foreground.
# Usage: run_cli_sender <subcommand> <vault_dir> <config_dir> <log_file> <code> <name>
#   subcommand is "secrets" or "dbs", name is the secret or database name to send.
#
run_cli_sender() {
    local subcommand="$1"
    local vault_dir="$2"
    local config_dir="$3"
    local log_file="$4"
    local code="$5"
    local name="$6"
    (
        cd "$CLI_DIR"
        PHOTOSPHERE_VAULT_DIR="$vault_dir" \
        PHOTOSPHERE_CONFIG_DIR="$config_dir" \
        PHOTOSPHERE_VAULT_TYPE=plaintext \
            bun run start -- "$subcommand" send --name "$name" --yes --code "$code"
    ) > "$log_file" 2>&1
}

#
# Marks the current test as passed and prints a green banner.
#
mark_pass() {
    log_success "$1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

#
# Marks the current test as failed, dumps the relevant logs, and records the name.
# Usage: mark_fail <test_name> <log_file...>
#
mark_fail() {
    local test_name="$1"
    shift
    log_error "$test_name failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_TEST_NAMES+=("$test_name")
    local log_file
    for log_file in "$@"; do
        if [ -f "$log_file" ]; then
            echo "---------- $log_file ----------"
            cat "$log_file"
            echo "---------- end $log_file ----------"
        fi
    done
}

# ============================================================================
# Test 1: CLI sender -> Desktop receiver (secret)
# ============================================================================
test_cli_to_desktop_secret() {
    local test_name="cli-to-desktop-secret"
    print_test_header 1 "$test_name"
    local test_tmp="$TMP_ROOT/$test_name"
    rm -rf "$test_tmp"
    mkdir -p "$test_tmp/desktop/vault" "$test_tmp/desktop/config" \
             "$test_tmp/cli/vault" "$test_tmp/cli/config"

    seed_secret "$test_tmp/cli/vault" "shared-api-key" "api-key" "API_VALUE_FROM_CLI"

    # Drawn per run, never hardcoded. A receiver announces sha256(code) to the whole subnet and a
    # sender takes the first announcement whose hash matches, so two shares on one code are
    # indistinguishable and pair with whoever they hear first, leaving the loser waiting out its
    # timeout. A fixed code collides with this same suite running from another worktree too.
    local code=$(( (RANDOM % 9000) + 1000 ))
    local app_port

    # start_app binds an OS-assigned port and publishes it as the APP_PORT global. Copy it into a
    # local so a later launch in the suite cannot change the port this test is talking to.
    start_app "$test_tmp/desktop" 0 || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; return; }
    app_port="$APP_PORT"
    wait_for_ready "$app_port" app_port || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" navigate '{"page":"secrets"}'
    wait_for_log "$test_tmp/desktop" "Secrets page loaded" || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" click '{"dataId":"receive-secret-button"}'
    wait_for_log "$test_tmp/desktop" "Receive secret dialog opened" || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" type "{\"dataId\":\"receive-secret-code-input\",\"text\":\"$code\"}"
    send_command "$app_port" click '{"dataId":"receive-secret-start-button"}'

    sleep 1
    local sender_log="$test_tmp/cli-sender.log"
    run_cli_sender "secrets" "$test_tmp/cli/vault" "$test_tmp/cli/config" "$sender_log" "$code" "shared-api-key"

    if ! grep -q "sent successfully" "$sender_log" 2>/dev/null; then
        mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    wait_for_log "$test_tmp/desktop" "Secret review step" "$LAN_TIMEOUT" || { mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" click '{"dataId":"receive-secret-save-button"}'
    wait_for_log "$test_tmp/desktop" "Secret saved" || { mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    if ! vault_has_secret "$test_tmp/desktop/vault" "shared-api-key"; then
        mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    stop_app "$app_port" "$test_tmp/desktop"
    mark_pass "$test_name"
}

# ============================================================================
# Test 2: CLI sender -> Desktop receiver (database + linked secrets)
# ============================================================================
test_cli_to_desktop_database() {
    local test_name="cli-to-desktop-database"
    print_test_header 2 "$test_name"
    local test_tmp="$TMP_ROOT/$test_name"
    rm -rf "$test_tmp"
    mkdir -p "$test_tmp/desktop/vault" "$test_tmp/desktop/config" \
             "$test_tmp/cli/vault" "$test_tmp/cli/config"

    seed_secret "$test_tmp/cli/vault" "s3-cli-key" "s3-credentials" \
        '{"region":"us-east-1","accessKeyId":"AKIATEST","secretAccessKey":"secret123","endpoint":"http://localhost:9000"}'
    seed_encryption_key "$test_tmp/cli/vault" "enc-cli-key"
    seed_databases_toml "$test_tmp/cli/config" "cli-shared-db" "s3:test-bucket:/photos" "s3-cli-key" "enc-cli-key"

    # Drawn per run, never hardcoded. See the note on the same line in the test above.
    local code=$(( (RANDOM % 9000) + 1000 ))
    local app_port

    # start_app binds an OS-assigned port and publishes it as the APP_PORT global. Copy it into a
    # local so a later launch in the suite cannot change the port this test is talking to.
    start_app "$test_tmp/desktop" 0 || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; return; }
    app_port="$APP_PORT"
    wait_for_ready "$app_port" app_port || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" navigate '{"page":"databases"}'
    wait_for_log "$test_tmp/desktop" "Databases page loaded" || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" click '{"dataId":"receive-database-button"}'
    wait_for_log "$test_tmp/desktop" "Receive database dialog opened" || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" type "{\"dataId\":\"receive-database-code-input\",\"text\":\"$code\"}"
    send_command "$app_port" click '{"dataId":"receive-database-start-button"}'

    sleep 1
    local sender_log="$test_tmp/cli-sender.log"
    run_cli_sender "dbs" "$test_tmp/cli/vault" "$test_tmp/cli/config" "$sender_log" "$code" "cli-shared-db"

    if ! grep -q "sent successfully" "$sender_log" 2>/dev/null; then
        mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    wait_for_log "$test_tmp/desktop" "Database review step" "$LAN_TIMEOUT" || { mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" click '{"dataId":"receive-database-save-button"}'
    wait_for_log "$test_tmp/desktop" "Database imported" || { mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    if [ ! -f "$test_tmp/desktop/config/databases.toml" ] || ! grep -q "cli-shared-db" "$test_tmp/desktop/config/databases.toml"; then
        mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    if ! vault_has_secret "$test_tmp/desktop/vault" "s3-cli-key" || ! vault_has_secret "$test_tmp/desktop/vault" "enc-cli-key"; then
        mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    stop_app "$app_port" "$test_tmp/desktop"
    mark_pass "$test_name"
}

# ============================================================================
# Test 3: Desktop sender -> CLI receiver (secret)
# ============================================================================
test_desktop_to_cli_secret() {
    local test_name="desktop-to-cli-secret"
    print_test_header 3 "$test_name"
    local test_tmp="$TMP_ROOT/$test_name"
    rm -rf "$test_tmp"
    mkdir -p "$test_tmp/desktop/vault" "$test_tmp/desktop/config" \
             "$test_tmp/cli/vault" "$test_tmp/cli/config"

    seed_secret "$test_tmp/desktop/vault" "desktop-api-key" "api-key" "API_VALUE_FROM_DESKTOP"

    local app_port

    # start_app binds an OS-assigned port and publishes it as the APP_PORT global. Copy it into a
    # local so a later launch in the suite cannot change the port this test is talking to.
    start_app "$test_tmp/desktop" 0 || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; return; }
    app_port="$APP_PORT"
    wait_for_ready "$app_port" app_port || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" navigate '{"page":"secrets"}'
    wait_for_log "$test_tmp/desktop" "Secrets page loaded" || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" click '{"dataId":"share-secret-button"}'
    send_command "$app_port" click '{"dataId":"share-secret-send-button"}'

    local code
    code=$(read_desktop_pairing_code "$app_port") || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }
    log_info "Desktop pairing code: $code"

    local receiver_log="$test_tmp/cli-receiver.log"
    start_cli_receiver "secrets" "$test_tmp/cli/vault" "$test_tmp/cli/config" "$receiver_log" "$code" || { mark_fail "$test_name" "$receiver_log" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    local elapsed=0
    while [ "$elapsed" -lt "$LAN_TIMEOUT" ]; do
        if grep -q "imported successfully" "$receiver_log" 2>/dev/null; then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if ! grep -q "imported successfully" "$receiver_log" 2>/dev/null; then
        mark_fail "$test_name" "$receiver_log" "$test_tmp/desktop/app.log"
        cleanup_cli_pids
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    if ! vault_has_secret "$test_tmp/cli/vault" "desktop-api-key"; then
        mark_fail "$test_name" "$receiver_log" "$test_tmp/desktop/app.log"
        cleanup_cli_pids
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    cleanup_cli_pids
    stop_app "$app_port" "$test_tmp/desktop"
    mark_pass "$test_name"
}

# ============================================================================
# Test 4: Desktop sender -> CLI receiver (database + linked secrets)
# ============================================================================
test_desktop_to_cli_database() {
    local test_name="desktop-to-cli-database"
    print_test_header 4 "$test_name"
    local test_tmp="$TMP_ROOT/$test_name"
    rm -rf "$test_tmp"
    mkdir -p "$test_tmp/desktop/vault" "$test_tmp/desktop/config" \
             "$test_tmp/cli/vault" "$test_tmp/cli/config"

    seed_secret "$test_tmp/desktop/vault" "s3-desktop-key" "s3-credentials" \
        '{"region":"us-east-1","accessKeyId":"AKIATEST","secretAccessKey":"secret123","endpoint":"http://localhost:9000"}'
    seed_encryption_key "$test_tmp/desktop/vault" "enc-desktop-key"
    seed_databases_toml "$test_tmp/desktop/config" "desktop-shared-db" "s3:desktop-bucket:/photos" "s3-desktop-key" "enc-desktop-key"

    local app_port

    # start_app binds an OS-assigned port and publishes it as the APP_PORT global. Copy it into a
    # local so a later launch in the suite cannot change the port this test is talking to.
    start_app "$test_tmp/desktop" 0 || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; return; }
    app_port="$APP_PORT"
    wait_for_ready "$app_port" app_port || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" navigate '{"page":"databases"}'
    wait_for_log "$test_tmp/desktop" "Databases page loaded" || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" click '{"dataId":"share-database-button"}'
    send_command "$app_port" click '{"dataId":"share-database-send-button"}'

    local code
    code=$(read_desktop_pairing_code "$app_port") || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }
    log_info "Desktop pairing code: $code"

    local receiver_log="$test_tmp/cli-receiver.log"
    start_cli_receiver "dbs" "$test_tmp/cli/vault" "$test_tmp/cli/config" "$receiver_log" "$code" || { mark_fail "$test_name" "$receiver_log" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    local elapsed=0
    while [ "$elapsed" -lt "$LAN_TIMEOUT" ]; do
        if grep -q "imported successfully" "$receiver_log" 2>/dev/null; then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if ! grep -q "imported successfully" "$receiver_log" 2>/dev/null; then
        mark_fail "$test_name" "$receiver_log" "$test_tmp/desktop/app.log"
        cleanup_cli_pids
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    if [ ! -f "$test_tmp/cli/config/databases.toml" ] || ! grep -q "desktop-shared-db" "$test_tmp/cli/config/databases.toml"; then
        mark_fail "$test_name" "$receiver_log" "$test_tmp/desktop/app.log"
        cleanup_cli_pids
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    if ! vault_has_secret "$test_tmp/cli/vault" "s3-desktop-key" || ! vault_has_secret "$test_tmp/cli/vault" "enc-desktop-key"; then
        mark_fail "$test_name" "$receiver_log" "$test_tmp/desktop/app.log"
        cleanup_cli_pids
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    cleanup_cli_pids
    stop_app "$app_port" "$test_tmp/desktop"
    mark_pass "$test_name"
}

# ============================================================================
# Main
# ============================================================================

rm -rf "$TMP_ROOT"
mkdir -p "$TMP_ROOT"

bundle_desktop

SUITE_START=$SECONDS

# Each test is held to the per-test timeout every suite in this repository shares. These tests are
# shell functions that report by incrementing counters here, so they go through the helper for that
# rather than being run in a subprocess. A test that runs out of time is killed, named, and counted
# as a failure below rather than leaving the suite waiting on it.
for lan_test in test_cli_to_desktop_secret test_cli_to_desktop_database \
                test_desktop_to_cli_secret test_desktop_to_cli_database; do
    tests_failed_before="$TESTS_FAILED"
    if ! run_test_function_with_timeout "$lan_test" "$lan_test"; then
        # A test killed for running too long never reached its own mark_fail, so the failure is
        # recorded here. Guarded on the counter so a test that failed normally is not counted twice.
        if [ "$TESTS_FAILED" -eq "$tests_failed_before" ]; then
            TESTS_FAILED=$(( TESTS_FAILED + 1 ))
            FAILED_TEST_NAMES+=("$lan_test")
        fi
    fi
done

SUITE_ELAPSED=$(( SECONDS - SUITE_START ))

echo ""
echo "============================================================================"
if [ "$TESTS_FAILED" -eq 0 ]; then
    echo "All $TESTS_PASSED tests passed (${SUITE_ELAPSED}s)"
else
    echo "$TESTS_FAILED of $(( TESTS_PASSED + TESTS_FAILED )) tests failed (${SUITE_ELAPSED}s)"
    echo "Failed tests:"
    for t in "${FAILED_TEST_NAMES[@]}"; do
        echo "  - $t"
    done
fi
echo "============================================================================"

exit "$TESTS_FAILED"
