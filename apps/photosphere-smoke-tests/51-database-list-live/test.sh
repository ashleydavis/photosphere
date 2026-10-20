#!/bin/bash

# A database created while the open-database dialog is showing appears in its list.
#
# On a phone and on a desktop the app creates a database without being asked: switching automatic import on makes the first pass create the default
# database and record it. That happens inside the worker, which writes both config files itself, so nothing in the web view is on the
# path and the interface used to find out only when it was next restarted. The dialog is opened before automatic import is switched on
# and is never closed, so the entry it ends up showing cannot have come from the read it did as it opened, because that read is
# asserted to have found nothing.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 51 "database-list-live"

# The name the app lists the database it makes for itself under.
DEFAULT_DATABASE_NAME="My Photos"

# The folder this scenario's photo goes in, which is what automatic import is pointed at. A desktop imports from folders and has none
# by default, and an Android phone would otherwise watch the whole photo library, so both are given this scenario's own.
#
# Not on iOS. The iOS shell lists every library item with no album, so automatic import there cannot be pointed at one and always
# watches the whole library, and the simulator has no supported way to take a seeded photo back out of its library, so a photo put in
# here would stay for every run after this one. Nothing is seeded there: the whole library, as the simulator ships it, is watched, and
# nothing this scenario asserts depends on what the library holds.
SEEDS_LIBRARY=1
if [ "$PLATFORM" = "ios" ]; then
    SEEDS_LIBRARY=0
fi
LIBRARY_PREFIX="psphere-database-list-live"
PHOTO_NAME="$LIBRARY_PREFIX-$$.jpeg"
if [ "$SEEDS_LIBRARY" -eq 1 ]; then
    LIBRARY="$("${PLATFORM}_library_dir" "$LIBRARY_PREFIX")"
fi

# Automatic import is left switched on by this scenario, and the app's data outlives it on a shared emulator, so it is wiped on the way
# out as well as on the way in.
on_exit() {
    local exit_code=$?
    cleanup_apps "$TMP_DIR"
    "${PLATFORM}_reset_app_state" >/dev/null 2>&1 || true
    if [ "$SEEDS_LIBRARY" -eq 1 ]; then
        "${PLATFORM}_library_remove" "$LIBRARY" "$PHOTO_NAME" 2>/dev/null || true
    fi
    return $exit_code
}
trap on_exit EXIT

"${PLATFORM}_reset_app_state" || exit 1

# Sweep up anything an earlier run left in the library, then put the photo in and point automatic import at the folder, switched off.
# Switching it on is what the scenario does through the settings card below.
if [ "$SEEDS_LIBRARY" -eq 1 ]; then
    "${PLATFORM}_library_sweep" "$LIBRARY_PREFIX" || exit 1
    "${PLATFORM}_library_add" "$LIBRARY" "$REPO_DIR/test/multiple-files/test-1.jpeg" "$PHOTO_NAME" || exit 1
    "${PLATFORM}_seed_library_auto_import_config" "false" "" "5000" "$LIBRARY" "$PHOTO_NAME" || exit 1
fi

# Grant the photo permission from outside the app, because the system dialog cannot be tapped by a test.
"${PLATFORM}_grant_media_permission" || exit 1

# And the notification permission: switching automatic import on starts a foreground service, which needs an ongoing notification.
"${PLATFORM}_grant_notification_permission" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Open the database dialog while there is nothing to list. It stays open for the rest of the scenario.
click_sidebar_item "$APP_PORT" open-database || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"

# The list is empty. Asserted rather than assumed, because a list that already held the database would make the final wait pass
# without anything having been refreshed.
wait_for_value "$APP_PORT" "no-databases-configured" "No databases configured"

# Switch automatic import on through the settings card, which opens over the database dialog.
click_sidebar_item "$APP_PORT" configuration || exit 1

# The card renders nothing until the settings are in, so the toggle carrying its label is the state to wait for.
wait_for_value "$APP_PORT" "auto-import-toggle" "Automatic import"

send_command "$APP_PORT" click '{"dataId":"auto-import-toggle"}' || exit 1

# The first pass creates the default database and records it, both inside the worker.
wait_for_log "$TMP_DIR" "$("${PLATFORM}_auto_import_started_log")" || exit 1

# Close the configuration dialog, leaving the database dialog on screen exactly as it was opened.
send_command "$APP_PORT" click '{"dataId":"configuration-dialog-close"}' || exit 1

# The worker says it has recorded the database...
wait_for_log "$TMP_DIR" "Databases changed" 180 || exit 1

# ...and the still-open dialog is now listing it. Nothing between the dialog opening and here closed it, reopened it, or asked it to
# refresh.
wait_for_value "$APP_PORT" "database-list-item-0" "$DEFAULT_DATABASE_NAME" 60

check_no_errors "$TMP_DIR"

log_success "Test 51 passed: database-list-live"
