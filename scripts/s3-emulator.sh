#!/usr/bin/env bash
# Starts and stops a local MinIO server for the S3 smoke tests, so an S3 test needs no credentials,
# no account and no configuration: it provisions its own server and can never skip.
#
# The server speaks PLAIN HTTP. There is no TLS here, and none is wanted: the real AWS SDK honours
# the `http://` scheme, so a certificate authority, a generated certificate, a device trust anchor
# and a TLS proxy are all unnecessary. If TLS ever appears in this file, something upstream has
# regressed to a client that ignores the URL scheme.
#
# The MinIO binary is downloaded once into a git-ignored repo-level cache and reused. The server
# binds an OS-assigned free port, so several suites can run at the same moment without colliding.
#
# Usage:
#   scripts/s3-emulator.sh start <state-dir>   Starts a server, seeds its bucket, writes <state-dir>/env.
#   scripts/s3-emulator.sh stop  <state-dir>   Stops the server recorded in <state-dir>. Safe if none is running.
#
# `start` writes a shell-sourceable <state-dir>/env exporting S3_EMULATOR_PORT, S3_EMULATOR_BUCKET,
# S3_EMULATOR_ACCESS_KEY and S3_EMULATOR_SECRET_KEY. `stop` never fails, so it is safe in a trap.
set -euo pipefail

# The pinned MinIO release. Pinned rather than tracking latest so a server-side release cannot change
# what the tests run against overnight.
MINIO_VERSION="RELEASE.2025-09-07T16-13-09Z"

# The bucket the tests browse, and the root credentials the server is started with. MinIO requires a
# root password of at least 8 characters. These are local-only test credentials for a server that
# lives for the duration of one test.
EMULATOR_BUCKET="photosphere-smoke-test"
EMULATOR_ACCESS_KEY="photosphereroot"
EMULATOR_SECRET_KEY="photospheresecret"

# The directory prefixes seeded into the bucket, which the S3 browser lists. Two are enough to assert
# the listing came back with real content in a stable order.
EMULATOR_PREFIXES="alpha-dir,beta-dir"

# Seconds to wait for the server to report healthy before giving up.
HEALTH_TIMEOUT_SECONDS=60

# How many times to retry the whole start when the server never becomes healthy. A free port is
# chosen, released, and only then bound by MinIO, so another process can take it in between; a fresh
# port on the next attempt is the fix for that narrow race.
START_ATTEMPTS=3

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Git-ignored cache for the downloaded binary, shared by every test and every worktree run.
CACHE_DIR="$REPO_ROOT/.s3-emulator-cache"

log() {
    printf '[s3-emulator] %s\n' "$1" >&2
}

#
# Prints the MinIO download platform slug ("linux-amd64" and friends) for this machine, failing with
# a clear message on a platform MinIO does not publish a binary for.
#
resolve_platform() {
    local osName archName
    case "$(uname -s)" in
        Linux*)  osName="linux" ;;
        Darwin*) osName="darwin" ;;
        # The smoke suites run under Git Bash on Windows, which reports MINGW64_NT. MinIO publishes a
        # windows-amd64 build at the same URL shape as the others.
        MINGW*|MSYS*|CYGWIN*) osName="windows" ;;
        *)
            echo "ERROR: the S3 emulator supports Linux, macOS and Windows only; this is $(uname -s)." >&2
            return 1
            ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  archName="amd64" ;;
        arm64|aarch64) archName="arm64" ;;
        *)
            echo "ERROR: the S3 emulator supports x86_64 and arm64 only; this is $(uname -m)." >&2
            return 1
            ;;
    esac
    echo "$osName-$archName"
}

#
# Downloads the pinned MinIO binary into the cache if it is not already there, and prints its path.
#
# The download goes to a `.partial` name that is moved into place only once curl has succeeded, so an
# interrupted download cannot leave a half-written file that the next run mistakes for a cached
# binary and tries to execute.
#
ensure_minio_binary() {
    local platform binaryExtension binaryPath partialPath
    platform="$(resolve_platform)"
    # Windows decides what it will execute from the file extension, and the published artifact carries
    # none, so the cached copy is named .exe there. Elsewhere the execute bit set below is enough.
    binaryExtension=""
    if [ "${platform%%-*}" = "windows" ]; then
        binaryExtension=".exe"
    fi
    binaryPath="$CACHE_DIR/minio-$platform-$MINIO_VERSION$binaryExtension"

    if [ -x "$binaryPath" ]; then
        echo "$binaryPath"
        return 0
    fi

    mkdir -p "$CACHE_DIR"
    partialPath="$binaryPath.partial"
    rm -f "$partialPath"
    log "Downloading MinIO $MINIO_VERSION for $platform (cached at $binaryPath)..."
    curl -sL --fail -o "$partialPath" \
        "https://dl.min.io/server/minio/release/$platform/archive/minio.$MINIO_VERSION"
    chmod +x "$partialPath"
    mv "$partialPath" "$binaryPath"
    echo "$binaryPath"
}

#
# Prints a port the OS says is free, by binding port 0 and reading back what was assigned.
#
# Never a hardcoded number: several smoke suites run at once out of one checkout, and a fixed port
# would make two of them fight over the same server.
#
find_free_port() {
    bun "$REPO_ROOT/scripts/find-free-port.ts"
}

#
# Polls the MinIO health endpoint until the server answers or the timeout expires.
# Usage: wait_for_health <port> <log_file>
#
wait_for_health() {
    local port="$1"
    local logFile="$2"
    local elapsed=0
    while [ "$elapsed" -lt "$HEALTH_TIMEOUT_SECONDS" ]; do
        if curl -sf --max-time 2 "http://127.0.0.1:$port/minio/health/live" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log "MinIO did not become healthy on port $port within ${HEALTH_TIMEOUT_SECONDS}s. Server log:"
    cat "$logFile" >&2 || true
    return 1
}

#
# Starts one MinIO server on a freshly chosen port, writing its pid and port into the state
# directory. Returns non-zero (leaving nothing running) when the server never becomes healthy.
# Usage: start_one_server <state_dir> <minio_binary>
#
start_one_server() {
    local stateDir="$1"
    local minioBinary="$2"
    local port serverPid

    port="$(find_free_port)"
    rm -f "$stateDir/minio.log"

    # `--address` fixes the S3 API port. `--console-address :0` lets the OS place the admin console
    # (on releases that still have one) rather than letting MinIO pick a fixed default port that a
    # parallel run would collide with.
    MINIO_ROOT_USER="$EMULATOR_ACCESS_KEY" \
    MINIO_ROOT_PASSWORD="$EMULATOR_SECRET_KEY" \
    MINIO_UPDATE=off \
        "$minioBinary" server "$stateDir/data" \
        --address ":$port" \
        --console-address ":0" \
        > "$stateDir/minio.log" 2>&1 &
    serverPid=$!
    echo "$serverPid" > "$stateDir/minio.pid"
    echo "$port" > "$stateDir/minio.port"

    if ! wait_for_health "$port" "$stateDir/minio.log"; then
        kill "$serverPid" 2>/dev/null || true
        rm -f "$stateDir/minio.pid" "$stateDir/minio.port"
        return 1
    fi

    log "MinIO listening on http://127.0.0.1:$port (pid $serverPid)"
    return 0
}

#
# Starts the emulator, seeds its bucket, and writes the sourceable env file.
# Usage: start <state_dir>
#
start_emulator() {
    local stateDir="$1"
    local minioBinary port attempt

    mkdir -p "$stateDir"
    # A stale server from an earlier run of this same state directory would otherwise be orphaned.
    stop_emulator "$stateDir"
    rm -rf "$stateDir/data" "$stateDir/env"
    mkdir -p "$stateDir/data"

    minioBinary="$(ensure_minio_binary)"

    attempt=1
    while [ "$attempt" -le "$START_ATTEMPTS" ]; do
        if start_one_server "$stateDir" "$minioBinary"; then
            break
        fi
        if [ "$attempt" -eq "$START_ATTEMPTS" ]; then
            echo "ERROR: MinIO failed to start after $START_ATTEMPTS attempts." >&2
            return 1
        fi
        log "Retrying MinIO start on a different port (attempt $((attempt + 1)) of $START_ATTEMPTS)..."
        attempt=$((attempt + 1))
    done

    port="$(cat "$stateDir/minio.port")"

    log "Seeding bucket $EMULATOR_BUCKET with prefixes $EMULATOR_PREFIXES..."
    if ! bun "$REPO_ROOT/scripts/seed-s3-bucket.ts" \
        --endpoint "http://127.0.0.1:$port" \
        --bucket "$EMULATOR_BUCKET" \
        --access-key "$EMULATOR_ACCESS_KEY" \
        --secret-key "$EMULATOR_SECRET_KEY" \
        --prefixes "$EMULATOR_PREFIXES" >&2; then
        log "Seeding failed. Server log:"
        cat "$stateDir/minio.log" >&2 || true
        stop_emulator "$stateDir"
        return 1
    fi

    cat > "$stateDir/env" <<ENV
export S3_EMULATOR_PORT="$port"
export S3_EMULATOR_BUCKET="$EMULATOR_BUCKET"
export S3_EMULATOR_ACCESS_KEY="$EMULATOR_ACCESS_KEY"
export S3_EMULATOR_SECRET_KEY="$EMULATOR_SECRET_KEY"
ENV

    log "Emulator ready. Source $stateDir/env for its settings."
}

#
# Stops the server recorded in the state directory. Always succeeds, including when nothing is
# running, so a test can put it in an unconditional trap.
# Usage: stop <state_dir>
#
stop_emulator() {
    local stateDir="$1"
    local pidFile="$stateDir/minio.pid"
    local serverPid

    if [ ! -f "$pidFile" ]; then
        return 0
    fi

    serverPid="$(cat "$pidFile" 2>/dev/null || true)"
    if [ -n "$serverPid" ] && kill -0 "$serverPid" 2>/dev/null; then
        kill -TERM "$serverPid" 2>/dev/null || true
        sleep 1
        kill -KILL "$serverPid" 2>/dev/null || true
        log "Stopped MinIO (pid $serverPid)."
    fi
    rm -f "$pidFile" "$stateDir/minio.port"
    return 0
}

main() {
    local command="${1:-}"
    local stateDir="${2:-}"

    if [ -z "$command" ] || [ -z "$stateDir" ]; then
        echo "Usage: $0 <start|stop> <state-dir>" >&2
        exit 1
    fi

    case "$command" in
        start) start_emulator "$stateDir" ;;
        stop)  stop_emulator "$stateDir" ;;
        *)
            echo "Usage: $0 <start|stop> <state-dir>" >&2
            exit 1
            ;;
    esac
}

main "$@"
