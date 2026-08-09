#!/bin/bash

# Smoke test: edit an asset's metadata in the UI and confirm it reached the database on disk.
#
# This covers the gallery EDIT path: persistDatabaseOps in
# packages/user-interface/src/context/asset-database-source.tsx POSTs the metadata ops to
# /apply-database-ops on the app's own asset server. Nothing else in this suite exercises that route.
# Test 18 looks like it should, but moving assets between databases goes through a background
# move-assets task and never touches the endpoint.
#
# The mobile suite has the same test (apps/smoke-tests/tests/46-edit-asset-metadata). They are a pair
# on purpose: the two shells run the same React code against different implementations of the asset
# server, Node's real express here and an express served over the embedded engine's TCP stream shim
# there, so having both is what says whether a failure is in the shared UI or in one shell's server.
#
# The check is made by reading the database back with the CLI rather than by reading the field in the
# app. The description input is bound to React state that onUpdateDescription sets before the POST is
# even sent, so reading it in place passes whether or not a single byte reached the disk. `psi info`
# is a separate process opening the database from scratch, so only a persisted edit can satisfy it.
#
# The AssetView is closed before the check because that is what flushes the write: the description
# goes through a 500ms lodash debounce, and AssetInfo's unmount effect flushes it. Waiting on a timer
# instead would be a race.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"
IMAGES_DIR="$REPO_DIR/test/multiple-files"

print_test_header 34 "edit-asset-metadata"

SOURCE_DB="$TMP_DIR/test-db"
DESCRIPTION="Edited in the gallery"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

log_info "Pre-creating database and importing a fixture..."
cd "$CLI_DIR" && bun run start -- init --db "$SOURCE_DB" --yes
cd "$CLI_DIR" && bun run start -- add "$IMAGES_DIR/test-1.jpeg" --db "$SOURCE_DB" --yes
cd "$DESKTOP_DIR"

log_info "Writing databases.toml..."
mkdir -p "$TMP_DIR/config"
cat > "$TMP_DIR/config/databases.toml" <<EOF
[[databases]]
name = "test-db"
description = ""
path = "$SOURCE_DB"
EOF

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

log_info "Opening database..."
send_command "$APP_PORT" open-database "{\"path\":\"$SOURCE_DB\"}"
wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded"
wait_for_log "$TMP_DIR" "Gallery items rendered"
log_success "Database opened with 1 asset"

# The thumb uses useLongPress, which only reacts to mousedown/mouseup, so a plain click is not enough.
log_info "Opening the AssetView..."
send_command "$APP_PORT" long-press-click '{"dataId":"gallery-thumb"}'
wait_for_log "$TMP_DIR" "AssetView opened"

log_info "Typing a description into the info panel..."
send_command "$APP_PORT" click '{"dataId":"open-info-button"}'
send_command "$APP_PORT" type "{\"dataId\":\"asset-description-input\",\"text\":\"$DESCRIPTION\"}"

# The field holding the text proves only that the keystrokes reached React. It is asserted anyway, so
# that a failure below reads as "the edit did not persist" rather than "the typing never landed".
wait_for_value "$APP_PORT" "asset-description-input" "$DESCRIPTION"
log_success "The description was typed into the info panel"

# Closing unmounts AssetInfo, whose unmount effect flushes the debounced write.
log_info "Closing the AssetView to flush the write..."
send_command "$APP_PORT" click '{"dataId":"asset-view-close-button"}'

# The app says when the write actually landed, so the CLI below is reading a database that has already
# been written to rather than racing one that is still being written.
wait_for_log "$TMP_DIR" "Database ops applied"

# --- The assertion: a separate process reads the description off the disk. ---

log_info "Reading the asset back out of the database with the CLI..."
ASSET_ID="$(cd "$CLI_DIR" && bun run start -- list --db "$SOURCE_DB" --yes 2>/dev/null | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
if [ -z "$ASSET_ID" ]; then
    log_error "Could not find the asset's id in the output of 'psi list'."
    exit 1
fi
log_info "Asset id: $ASSET_ID"

# Polled rather than read once: the POST is in flight when the AssetView closes, so the bytes may not
# have landed the instant this runs. A single read here would be a race that fails intermittently.
INFO_OUTPUT=""
FOUND=""
for _attempt in $(seq 1 30); do
    INFO_OUTPUT="$(cd "$CLI_DIR" && bun run start -- info "$ASSET_ID" --db "$SOURCE_DB" --yes 2>&1)"
    if echo "$INFO_OUTPUT" | grep -qF "$DESCRIPTION"; then
        FOUND="1"
        break
    fi
    sleep 1
done

if [ -z "$FOUND" ]; then
    log_error "The edit never reached the database on disk."
    log_error "'psi info $ASSET_ID' does not report the description \"$DESCRIPTION\". It said:"
    echo "$INFO_OUTPUT" | sed 's/^/  /'
    exit 1
fi
log_success "The edit reached the database on disk: 'psi info' reports the new description"

check_no_errors "$TMP_DIR"

log_success "Test 34 passed: edit-asset-metadata"
