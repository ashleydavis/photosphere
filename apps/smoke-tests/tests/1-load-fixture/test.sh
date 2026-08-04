#!/bin/bash

# Mobile port of desktop 1-load-fixture. Seeds the checked-in 50-assets fixture into the app's
# private storage sandbox, opens it, and expects the gallery to load 50 assets. This exercises the
# real mobile read path: open-database -> load-assets task -> embedded worker -> FileStorage over the
# native host fs functions -> bdb -> asset pages streamed back to the gallery.
#
# The fixture is the same one the desktop test points at (test/dbs/50-assets), copied onto the
# device sandbox (host paths do not exist on device, and the native PathSandbox only allows paths
# relative to the storage root), so the database is opened by its sandbox-relative name.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 1 "load-fixture"

# The fixture's sandbox-relative name (under the app's private files directory).
DB_NAME="50-assets"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Seed the fixture into the app sandbox before opening it.
"${PLATFORM}_seed_database" "$REPO_DIR/test/dbs/$DB_NAME" "$DB_NAME"

send_command "$APP_PORT" open-database "{\"path\":\"$DB_NAME\"}" || exit 1

wait_for_log "$TMP_DIR" "Gallery loaded: 50 assets"

# The gallery renders the 50 assets from the loaded metadata and upgrades each tile from its embedded
# micro-thumbnail to a full thumbnail, fetched over the embedded asset server:
# http://localhost:<port>/asset?type=thumb&db=50-assets, served from device storage by the asset-server
# background task over the native TCP socket. With that layer in place the thumbnail fetches succeed, so
# no asset-load errors are tolerated here.
check_no_errors "$TMP_DIR" || exit 1

# Directly confirm the embedded asset server serves real thumbnail bytes on device (the same request the
# WebView <img> makes): read the bound port from logcat, forward it to the host, and assert a JPEG body.
if [ "$PLATFORM" = "android" ]; then
    ASSET_ID="$(ls "$REPO_DIR/test/dbs/$DB_NAME/thumb" | head -1)"
    SERVER_PORT="$(adb logcat -d 2>/dev/null | grep -oE 'Asset server task listening on http://127.0.0.1:[0-9]+' | tail -1 | grep -oE '[0-9]+$')"
    if [ -z "$SERVER_PORT" ]; then
        log_error "Asset server did not report a bound port"
        exit 1
    fi
    # Let adb pick and bind the host port atomically (tcp:0 prints the assigned port), rather than
    # pre-picking one that a parallel run could grab in the gap before the forward is set.
    HOST_PORT="$(adb forward tcp:0 "tcp:$SERVER_PORT")"
    THUMB_OUT="$TMP_DIR/served-thumb.bin"
    # The literal loopback address, never the name: adb assigns this forward a port from the same
    # ephemeral range the emulators draw their [::1] console ports from, and curl resolves the name
    # "localhost" to ::1 first, which would reach the emulator console instead of the forward. See
    # BRIDGE_HOST in lib/common.sh.
    HTTP_CODE="$(curl -s -o "$THUMB_OUT" -w '%{http_code}' --max-time 10 "http://$BRIDGE_HOST:$HOST_PORT/asset?id=$ASSET_ID&type=thumb&db=$DB_NAME")"
    adb forward --remove "tcp:$HOST_PORT" >/dev/null 2>&1 || true
    if [ "$HTTP_CODE" != "200" ]; then
        log_error "Asset server returned HTTP $HTTP_CODE for thumbnail $ASSET_ID"
        exit 1
    fi
    if ! file "$THUMB_OUT" | grep -q "JPEG image data"; then
        log_error "Asset server did not return JPEG thumbnail bytes (got: $(file "$THUMB_OUT"))"
        exit 1
    fi
    log_success "Asset server served a JPEG thumbnail over $BRIDGE_HOST:$HOST_PORT"
fi

log_success "Test 1 passed: load-fixture"
