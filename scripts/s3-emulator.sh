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
# binds a randomly chosen free port, so several suites can run at the same moment without colliding.
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

# How many times to try seeding the bucket, and how long to wait between tries.
#
# The health endpoint answers as soon as the process is listening, which is before MinIO has finished
# formatting its erasure pool. A request in that window comes back
# "XMinioServerNotInitialized: Server not initialized yet, please try again", which is the server
# telling the client to retry rather than a real failure. Without this the seed failed outright and
# took the whole test with it, seen twice while writing the S3 tests.
SEED_ATTEMPTS=10
SEED_RETRY_DELAY_SECONDS=1

# How many times to retry the whole start when the server never becomes healthy. A port is checked
# for being free and only then bound by MinIO, so another process can take it in between; a fresh
# port on the next attempt is the fix for that narrow race.
START_ATTEMPTS=3

# The range a candidate port is drawn from, and how many candidates to try before giving up. The
# range sits above the registered ports in common use and below 32768, where Linux begins its
# ephemeral range, so nothing else is being handed these numbers automatically.
PORT_RANGE_START=20000
PORT_RANGE_SIZE=12768
PORT_ATTEMPTS=50

# Where a chosen port is recorded so no other emulator picks it.
#
# A fixed machine-wide path, not a per-test one: several suites, and several worktrees, start
# emulators at the same moment, and a reservation only prevents a collision if every starter can see
# it. One directory per port, created with mkdir, which the OS makes atomic: of several starts
# racing for the same number exactly one succeeds and the rest move on to another port.
#
# Without this two emulators bound the same port and stayed there. MinIO probes the port before
# binding, but the probe is not the bind, and it sets SO_REUSEPORT, so two servers starting close
# enough together both succeed. The kernel then split connections between them and requests landed
# on whichever server it chose, giving "The specified bucket does not exist" against a bucket that
# had just been created.
PORT_RESERVATION_DIR="${PHOTOSPHERE_S3_PORT_DIR:-/tmp/photosphere-s3-emulator-ports}"

# How old a reservation must be before it is treated as abandoned. A run killed between reserving a
# port and releasing it leaves its directory behind, and nothing else would ever remove it.
#
# This is spelled as `find -mtime` takes it, because that is the only thing it is ever passed to and
# converting a friendlier unit here would only invite getting the conversion wrong. `+0` means "last
# changed more than a full day ago", which no live run can be: nothing here runs for a day.
RESERVATION_STALE_MTIME="+0"

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
# The download goes to a uniquely named temporary file that is moved into place only once curl has
# succeeded, so an interrupted download cannot leave a half-written file that the next run mistakes
# for a cached binary and tries to execute.
#
# The temporary name has to be unique per download, and was not: it used to be a fixed
# "<binary>.partial". Every S3 test starts its own emulator, so on a cold cache several of them
# download at once, and they all wrote to that one path. When the first finished and renamed it into
# place, the others were still writing to the same inode, which by then was the cached binary, and
# anything that tried to run it got ETXTBSY, "Text file busy". That is how a fresh checkout failed
# four S3 tests on its first run.
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
    partialPath="$(mktemp "$binaryPath.partial.XXXXXX")"
    log "Downloading MinIO $MINIO_VERSION for $platform (cached at $binaryPath)..."
    curl -sL --fail -o "$partialPath" \
        "https://dl.min.io/server/minio/release/$platform/archive/minio.$MINIO_VERSION"
    chmod +x "$partialPath"
    # A rename onto the final path, which is atomic, so a concurrent downloader either sees no
    # cached binary at all or sees a complete one. Whichever download lands last wins, and they are
    # all the same pinned version, so which one wins does not matter.
    mv "$partialPath" "$binaryPath"
    echo "$binaryPath"
}

#
# Reclaims reservations left behind by a run that was killed before it could release its port.
# Anything older than RESERVATION_STALE_MTIME cannot belong to a live run, because no run lasts a
# day. Without this the reservation directory would only ever grow, and the range would fill.
#
# The directories are always empty, so `rmdir` is used rather than a recursive delete: it refuses to
# touch anything that unexpectedly has content in it.
#
collect_stale_reservations() {
    find "$PORT_RESERVATION_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "$RESERVATION_STALE_MTIME" \
        -exec rmdir {} + 2>/dev/null || true
    return 0
}

#
# Prints a port that nothing is listening on AND that no other emulator has claimed, having claimed
# it for this caller. Release it with release_port_reservation once the server it is for has gone.
#
# Two checks, because they catch different things. `mkdir` of the port's reservation directory is
# atomic, so of several emulators racing for the same number exactly one wins and the losers pick
# again; that is what stops two of our own servers landing on one port. The /dev/tcp connect then
# catches a port that something outside the tests is already using, which no reservation would know
# about.
#
# Reserving is not merely a nicety here: MinIO checks the port before binding it but sets
# SO_REUSEPORT when it does bind, so two servers starting close together both succeed and the kernel
# splits connections between them. Checking the port alone cannot prevent that, because the answer
# goes stale in the seconds MinIO takes to start.
#
# Never a hardcoded number: several smoke suites run at once out of one checkout, and a fixed port
# would make two of them fight over the same server.
#
# The range stops below 32768, where Linux starts handing out ephemeral ports, so a port picked here
# cannot also be handed to an unrelated process as the local end of an outgoing connection.
#
reserve_free_port() {
    local port attempt
    mkdir -p "$PORT_RESERVATION_DIR"
    collect_stale_reservations
    attempt=1
    while [ "$attempt" -le "$PORT_ATTEMPTS" ]; do
        port=$(( PORT_RANGE_START + RANDOM % PORT_RANGE_SIZE ))
        if mkdir "$PORT_RESERVATION_DIR/$port" 2>/dev/null; then
            if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
                echo "$port"
                return 0
            fi
            # Claimed by us but occupied by something else, so hand the claim straight back rather
            # than sitting on a number this emulator will never use.
            release_port_reservation "$port"
        fi
        attempt=$((attempt + 1))
    done
    echo "ERROR: no free port found in $PORT_ATTEMPTS attempts between $PORT_RANGE_START and $((PORT_RANGE_START + PORT_RANGE_SIZE - 1))." >&2
    return 1
}

#
# Gives a reserved port back so a later emulator can use it. Always succeeds, including when the
# port was never reserved, so it is safe on every failure path.
# Usage: release_port_reservation <port>
#
release_port_reservation() {
    local port="$1"

    if [ -z "$port" ]; then
        return 0
    fi
    rmdir "$PORT_RESERVATION_DIR/$port" 2>/dev/null || true
    return 0
}

#
# Polls the MinIO health endpoint until the server answers or the timeout expires.
#
# The server's own pid is watched as well as the port, because the port answering is not proof that
# OUR server answered: a MinIO that fails to bind exits immediately, and if anything else is on that
# port the health check would pass against a stranger's server and this emulator would go on to seed
# and hand out someone else's. Giving up as soon as the process is gone also turns a dead server
# into an immediate retry instead of a full HEALTH_TIMEOUT_SECONDS wait.
#
# Usage: wait_for_health <port> <log_file> <server_pid>
#
wait_for_health() {
    local port="$1"
    local logFile="$2"
    local serverPid="$3"
    # A deadline read off bash's SECONDS, polled four times a second. The server is usually up in
    # well under a second, and a whole second between looks was charged to every suite that starts
    # one. The timeout it is held to is unchanged.
    local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
    while [ "$SECONDS" -lt "$deadline" ]; do
        # Our process is checked before the port, not after: once it has exited, a healthy answer
        # from that port can only have come from somebody else's server, and treating that as
        # success is the very thing this is here to prevent.
        if ! kill -0 "$serverPid" 2>/dev/null; then
            log "MinIO exited before it became healthy on port $port. Server log:"
            cat "$logFile" >&2 || true
            return 1
        fi
        if curl -sf --max-time 2 "http://127.0.0.1:$port/minio/health/live" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.25
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

    port="$(reserve_free_port)"
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

    if ! wait_for_health "$port" "$stateDir/minio.log" "$serverPid"; then
        kill "$serverPid" 2>/dev/null || true
        rm -f "$stateDir/minio.pid" "$stateDir/minio.port"
        release_port_reservation "$port"
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
    local minioBinary port attempt seedAttempt

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
    seedAttempt=1
    while true; do
        if bun "$REPO_ROOT/scripts/seed-s3-bucket.ts" \
            --endpoint "http://127.0.0.1:$port" \
            --bucket "$EMULATOR_BUCKET" \
            --access-key "$EMULATOR_ACCESS_KEY" \
            --secret-key "$EMULATOR_SECRET_KEY" \
            --prefixes "$EMULATOR_PREFIXES" >&2; then
            break
        fi
        if [ "$seedAttempt" -ge "$SEED_ATTEMPTS" ]; then
            log "Seeding failed after $SEED_ATTEMPTS attempts. Server log:"
            cat "$stateDir/minio.log" >&2 || true
            stop_emulator "$stateDir"
            return 1
        fi
        log "Seeding attempt $seedAttempt failed; retrying in ${SEED_RETRY_DELAY_SECONDS}s..."
        sleep "$SEED_RETRY_DELAY_SECONDS"
        seedAttempt=$((seedAttempt + 1))
    done

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
    local serverPid port

    # Read the port before the early return below, and give the reservation back on every path out
    # of here. A state directory that has a port but no pid belongs to a run that died between
    # reserving and starting, and its port would otherwise stay claimed until the daily sweep.
    port="$(cat "$stateDir/minio.port" 2>/dev/null || true)"

    if [ ! -f "$pidFile" ]; then
        release_port_reservation "$port"
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
    release_port_reservation "$port"
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
