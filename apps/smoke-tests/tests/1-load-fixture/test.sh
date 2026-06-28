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

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

# The fixture's sandbox-relative name (under the app's private files directory).
DB_NAME="50-assets"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Seed the fixture into the app sandbox before opening it.
"${PLATFORM}_seed_database" "$REPO_DIR/test/dbs/$DB_NAME" "$DB_NAME"

send_command "$APP_PORT" open-database "{\"path\":\"$DB_NAME\"}" || exit 1

wait_for_log "$TMP_DIR" "Gallery loaded: 50 assets" 30

# The gallery renders the 50 assets from the loaded metadata. It also tries to upgrade each tile
# from its embedded micro-thumbnail to a full thumbnail, which requires the mobile asset-serving
# layer (plan-mobile-serving-options.md) that is not built yet, so those thumbnail fetches error.
# Ignore exactly those serving errors here; any other error still fails this test.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 1 passed: load-fixture"
