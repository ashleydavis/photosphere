#!/bin/bash

# Helpers shared by the LAN share smoke tests (125 to 135). Sourced after common.sh, which provides
# the logging, test_passed, test_failed, seed_vault_secret, seed_databases_config, get_cli_command and
# get_zig_cli_command. Sourcing this sets the test's exit trap, so a LAN share test sets none of its
# own. See lan-share.md beside this file.

# Stopping the processes a test starts, by recorded pid and with their whole tree.
source "$REPO_ROOT/scripts/lib/process-control.sh"

# macOS ships no `sha256sum`, and the broadcast capture hashes the pairing code with it. Defined only
# when the real command is missing, so Linux and Windows keep running the real one.
if [ -z "$(type -P sha256sum 2>/dev/null)" ]; then
    #
    # Prints SHA-256 hashes in sha256sum's format, with the shasum macOS has.
    # Usage: sha256sum [file...]
    #
    sha256sum() {
        shasum -a 256 "$@"
    }
fi

# The sender's vault directory, set by use_test_temp_dir.
SENDER_VAULT_DIR=""

# The sender's config directory, set by use_test_temp_dir.
SENDER_CONFIG_DIR=""

# The receiver's vault directory, set by use_test_temp_dir.
RECEIVER_VAULT_DIR=""

# The receiver's config directory, set by use_test_temp_dir.
RECEIVER_CONFIG_DIR=""

#
# Points the four sender and receiver locations every test builds its paths from at the given
# directory. The temp, cache, vault and config settings every psi process resolves are already
# pointed at the test's own directory by the runner and common.sh.
# Usage: use_test_temp_dir <dir>
#
use_test_temp_dir() {
    local dir="$1"
    SENDER_VAULT_DIR="${dir}/sender-vault"
    SENDER_CONFIG_DIR="${dir}/sender-config"
    RECEIVER_VAULT_DIR="${dir}/receiver-vault"
    RECEIVER_CONFIG_DIR="${dir}/receiver-config"
}

use_test_temp_dir "$TEST_TMP_DIR"
mkdir -p "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"

# The Zig port of psi (apps/cli-zig), which the runner built for this run.
ZIG_CLI_CMD="$(get_zig_cli_command)"

# The TypeScript CLI, for the interop tests: from source, or the compiled one under --binary.
TS_CLI_CMD="$(get_cli_command)"

# The CLI the sending side of a share runs in. An interop test swaps it for the TypeScript CLI.
SENDER_CLI_CMD="$ZIG_CLI_CMD"

# The CLI the receiving side of a share runs in. An interop test swaps it for the TypeScript CLI.
RECEIVER_CLI_CMD="$ZIG_CLI_CMD"

# Active receiver pid, killed by test_cleanup.
RECEIVER_PID=""

# Every process this test started, so cleanup can reach all of them by pid.
#
# Nothing here may ever select a process by matching its command line. `pkill -f` and anything like it
# asks the kernel about every process on the machine, and the CLI's command line is the same whichever
# checkout or worktree launched it, so it kills another run's identical process. A recorded pid
# belongs to this run and to nothing else.
TEST_PIDS=()

# The same pids on disk, for anything that runs in a subshell. A subshell gets a copy of the shell's
# variables, so a pid it records in TEST_PIDS is lost when it returns; a file is shared, so
# lan_share_exit reads what every subshell recorded, including capture_receiver_broadcast's listener,
# which runs inside a command substitution.
TEST_PID_FILE="$TEST_TMP_DIR/test-pids"
: > "$TEST_PID_FILE"

#
# Kills a process and its descendants, and reaps it.
#
# `bun run start` runs the actual CLI in a child process that owns the UDP broadcast and HTTPS
# server. Killing only the top-level pid orphans that child, which keeps broadcasting its pairing
# code. kill_process_tree takes the whole tree, which prevents the orphan.
# Usage: kill_proc <pid>
#
kill_proc() {
    local pid="$1"
    kill_process_tree "$pid"
    wait "$pid" 2>/dev/null || true
}

#
# Records a process this test started, in the array cleanup reads and the file lan_share_exit reads.
# Usage: track_test_pid <pid>
#
track_test_pid() {
    local pid="$1"
    TEST_PIDS+=("$pid")
    if [ -n "$TEST_PID_FILE" ]; then
        echo "$pid" >> "$TEST_PID_FILE"
    fi
}

#
# Runs a CLI command, recording its pid so it can be killed if the test hangs, and returns its exit
# code once it finishes.
#
# Backgrounding and waiting rather than running in the foreground is the whole point: a foreground
# child has no pid anything else can see. `wait` on a known pid gives the same blocking behaviour and
# the same exit code.
# Usage: run_cli_tracked <log_file> <args...>
#
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

#
# Kills everything this test recorded in TEST_PIDS, deepest process first, and forgets them.
#
# The tree walk matters as much as the pid does: `bun run` is a wrapper, and the process that owns the
# UDP broadcast and the HTTPS server is its child. Killing only the wrapper leaves that child running
# and broadcasting.
# Usage: kill_test_pids
#
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

#
# Kills any active receiver and anything else the test started.
# Usage: test_cleanup
#
test_cleanup() {
    if [ -n "$RECEIVER_PID" ]; then
        kill_proc "$RECEIVER_PID"
        RECEIVER_PID=""
    fi
    kill_test_pids
}

#
# The test's exit trap, run before cleanup_and_show_summary. Kills every pid recorded in the pid
# file (which holds the ones subshells recorded and TEST_PIDS cannot see), then everything
# test_cleanup knows of, then any job still running, and returns the exit code the test exited with
# so cleanup_and_show_summary reports it.
# Usage: trap 'lan_share_exit; cleanup_and_show_summary' EXIT
#
lan_share_exit() {
    local exit_code=$?
    local recorded_pid
    if [ -f "$TEST_PID_FILE" ]; then
        while IFS= read -r recorded_pid; do
            if [ -n "$recorded_pid" ]; then
                kill_process_tree "$recorded_pid"
            fi
        done < "$TEST_PID_FILE"
    fi
    test_cleanup
    local job_pid
    for job_pid in $(jobs -p 2>/dev/null); do
        kill_process_tree "$job_pid"
    done
    wait 2>/dev/null || true
    return $exit_code
}
trap 'lan_share_exit; cleanup_and_show_summary' EXIT

#
# Merges one secret into a vault directory's single vault.json file, which holds every secret keyed
# by its name. The merge is a read-modify-write, so seeding a second secret keeps the first. An absent
# vault file starts from an empty object, and a vault file that does not parse fails the test rather
# than being silently replaced with a fresh one.
# Usage: merge_vault_secret <vault_dir> <secret_json>
#
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
        test_failed "Vault file $vault_file is not valid JSON"
    fi
    printf '%s' "$merged" > "$vault_file"
    chmod 600 "$vault_file"
}

#
# Seeds a secret whose value is read verbatim from a file, newlines and all, which is how a
# multi-line PEM gets in. jq --rawfile keeps the file's exact bytes, including any trailing newline,
# which $(cat ...) would strip.
# Usage: seed_vault_secret_from_file <vault_dir> <secret_name> <secret_type> <value_file>
#
seed_vault_secret_from_file() {
    local vault_dir="$1"
    local secret_name="$2"
    local secret_type="$3"
    local value_file="$4"

    merge_vault_secret "$vault_dir" "$(jq -cn --arg name "$secret_name" --arg type "$secret_type" --rawfile value "$value_file" \
        '{name: $name, type: $type, value: $value}')"
}

#
# Prints the number of secrets held in a vault directory's vault.json, or 0 when the file is absent.
# Usage: count_vault_secrets <vault_dir>
#
count_vault_secrets() {
    local vault_dir="$1"
    local vault_file="${vault_dir}/vault.json"

    if [ ! -f "$vault_file" ]; then
        printf '0'
        return 0
    fi
    jq 'length' "$vault_file"
}

#
# Starts a receiver in the background with the given pairing code and waits for it to be ready. Sets
# RECEIVER_PID. Fails the test if the receiver exits first or is not ready within 60 seconds.
#
# The budget is generous because it is measuring how long a `bun` process takes to start, load the
# CLI and bind its sockets, on a machine that may be running a dozen other suites. Waiting longer
# costs nothing: a receiver that died is caught on the next pass by the pid check, and a receiver that
# is alive but wedged is caught by the runner's per-test timeout.
# Usage: start_receiver_with_code <dbs|secrets> <log_file> <code>
#
start_receiver_with_code() {
    local cmd_prefix="$1"
    local log_file="$2"
    local code="$3"

    PHOTOSPHERE_VAULT_DIR="$RECEIVER_VAULT_DIR" \
    PHOTOSPHERE_CONFIG_DIR="$RECEIVER_CONFIG_DIR" \
        $RECEIVER_CLI_CMD $cmd_prefix receive --yes --code "$code" > "$log_file" 2>&1 &
    RECEIVER_PID=$!
    track_test_pid "$RECEIVER_PID"

    local attempt
    for attempt in $(seq 1 300); do
        sleep 0.2
        if [ -f "$log_file" ] && grep -q "Waiting for sender" "$log_file" 2>/dev/null; then
            # Give the HTTPS server and UDP broadcast a moment to be fully ready.
            sleep 0.3
            return 0
        fi
        # Also check for an early exit indicating an error.
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            cat "$log_file" 2>/dev/null || true
            test_cleanup
            test_failed "Receiver process exited unexpectedly."
        fi
    done

    cat "$log_file" 2>/dev/null || true
    test_cleanup
    test_failed "Receiver was not ready within 60 seconds."
}

#
# Waits for the receiver to finish and exit, so its vault and config are complete before a test reads
# them.
#
# A sender reports success as soon as the receiver has accepted the payload, and only then does the
# receiver import it, so the sender exiting says nothing about whether the receiver's files have been
# written yet. Waiting on the receiver's own pid waits exactly as long as the import takes. A receiver
# that never exits is caught by the runner's per-test timeout.
# Usage: wait_for_receiver_exit
#
wait_for_receiver_exit() {
    wait "$RECEIVER_PID" 2>/dev/null || true
    RECEIVER_PID=""
}

#
# Captures the running receiver's UDP discovery broadcast and prints it, as
# PSIE_RECV:{port}:{codeHash}:{fingerprint}, or prints nothing when none was captured.
#
# test/udp-listen.ts exits by itself on the first broadcast carrying the given code hash, so this
# waits on the events themselves with no time limit of its own: it returns when the listener has
# exited, or kills the listener when the receiver (RECEIVER_PID) is no longer alive, since a dead
# receiver will never broadcast. A receiver that stays alive and never broadcasts is wedged, and the
# runner's per-test timeout ends it.
#
# Only the listener's stdout is printed. Its stderr goes to <log_file>.stderr, so nothing `bun`
# writes there reaches the text the tests parse, and it is still readable when a capture fails.
# Usage: capture_receiver_broadcast <code_hash> <log_file>
#
capture_receiver_broadcast() {
    local code_hash="$1"
    local log_file="$2"

    bun run test/udp-listen.ts "$code_hash" > "$log_file" 2> "${log_file}.stderr" &
    local listen_pid=$!
    track_test_pid "$listen_pid"

    while kill -0 "$listen_pid" 2>/dev/null; do
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            kill_process_tree "$listen_pid"
            break
        fi
        sleep 0.2
    done
    wait "$listen_pid" 2>/dev/null || true

    cat "$log_file"
}

#
# Shares a database from the sender to the receiver over the LAN, each side in the CLI named by
# SENDER_CLI_CMD and RECEIVER_CLI_CMD, and fails the test unless the sender and the receiver both
# report success, the receiver's vault holds the shared secrets and its database list holds the
# entry.
# Usage: share_database_and_check
#
share_database_and_check() {
    log_info "--- Test: Share a database over LAN (CLI) ---"

    PHOTOSPHERE_VAULT_DIR="$SENDER_VAULT_DIR" seed_vault_secret "s3sender" "s3-credentials" \
        '{"region":"us-east-1","accessKeyId":"AKIATEST","secretAccessKey":"secret123","endpoint":"http://localhost:9000"}'

    # Generate a real RSA-2048 PEM so resolveDatabaseSharePayload can derive the public key.
    local pem_file="${TEST_TMP_DIR}/encsndr1.pem"
    mkdir -p "$TEST_TMP_DIR" "$SENDER_VAULT_DIR"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$pem_file" 2>/dev/null
    seed_vault_secret_from_file "$SENDER_VAULT_DIR" "encsndr1" "encryption-key" "$pem_file"

    PHOTOSPHERE_CONFIG_DIR="$SENDER_CONFIG_DIR" seed_databases_config \
        '[{"name":"share-test-db","description":"A database for LAN share testing","path":"s3:test-bucket/photos","s3Key":"s3sender","encryptionKey":"encsndr1"}]'

    local test_code
    test_code="$(allocate_pairing_code)"
    local receiver_log="${TEST_TMP_DIR}/receiver-db.log"
    start_receiver_with_code "dbs" "$receiver_log" "$test_code"

    local sender_log="${TEST_TMP_DIR}/sender-db.log"
    run_cli_tracked "$sender_log" env \
        PHOTOSPHERE_VAULT_DIR="$SENDER_VAULT_DIR" \
        PHOTOSPHERE_CONFIG_DIR="$SENDER_CONFIG_DIR" \
        $SENDER_CLI_CMD dbs send --name share-test-db --yes --code "$test_code" || true

    if grep -q "sent successfully" "$sender_log" 2>/dev/null; then
        log_success "Database share: sender reports success"
    else
        cat "$sender_log" 2>/dev/null || true
        test_failed "Database share: sender did not report success"
    fi

    wait_for_receiver_exit

    local receiver_secrets
    receiver_secrets=$(count_vault_secrets "$RECEIVER_VAULT_DIR")
    if [ "$receiver_secrets" -ge 1 ]; then
        log_success "Database share: receiver vault has $receiver_secrets secret(s)"
    else
        test_failed "Database share: receiver vault is empty after share"
    fi

    if grep -q "imported successfully" "$receiver_log" 2>/dev/null; then
        log_success "Database share: receiver reports success"
    else
        test_failed "Database share: receiver did not report success"
    fi

    if [ -f "${RECEIVER_CONFIG_DIR}/databases.toml" ] && grep -q "share-test-db" "${RECEIVER_CONFIG_DIR}/databases.toml"; then
        log_success "Database share: receiver has database entry"
    else
        test_failed "Database share: receiver databases.toml missing expected entry"
    fi
}

#
# Shares a secret from the sender to the receiver over the LAN, each side in the CLI named by
# SENDER_CLI_CMD and RECEIVER_CLI_CMD, and fails the test unless the sender and the receiver both
# report success and the receiver's vault holds the secret.
# Usage: share_secret_and_check
#
share_secret_and_check() {
    log_info "--- Test: Share a secret over LAN (CLI) ---"

    PHOTOSPHERE_VAULT_DIR="$SENDER_VAULT_DIR" seed_vault_secret "apikey01" "api-key" \
        'AIzaFakeKey123'

    local test_code
    test_code="$(allocate_pairing_code)"
    local receiver_log="${TEST_TMP_DIR}/receiver-secret.log"
    start_receiver_with_code "secrets" "$receiver_log" "$test_code"

    local sender_log="${TEST_TMP_DIR}/sender-secret.log"
    run_cli_tracked "$sender_log" env \
        PHOTOSPHERE_VAULT_DIR="$SENDER_VAULT_DIR" \
        PHOTOSPHERE_CONFIG_DIR="$SENDER_CONFIG_DIR" \
        $SENDER_CLI_CMD secrets send --name "apikey01" --yes --code "$test_code" || true

    if grep -q "sent successfully" "$sender_log" 2>/dev/null; then
        log_success "Secret share: sender reports success"
    else
        cat "$sender_log" 2>/dev/null || true
        test_failed "Secret share: sender did not report success"
    fi

    wait_for_receiver_exit

    local receiver_secrets
    receiver_secrets=$(count_vault_secrets "$RECEIVER_VAULT_DIR")
    if [ "$receiver_secrets" -ge 1 ]; then
        log_success "Secret share: receiver vault has $receiver_secrets secret(s)"
    else
        test_failed "Secret share: receiver vault is empty after share"
    fi

    if grep -q "imported successfully" "$receiver_log" 2>/dev/null; then
        log_success "Secret share: receiver reports success"
    else
        test_failed "Secret share: receiver did not report success"
    fi
}
