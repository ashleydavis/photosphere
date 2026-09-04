#!/bin/bash

# A database created while the open-database dialog is showing appears in its list.
#
# On a phone the app creates a database without being asked: switching automatic import on makes the
# first pass create the default database and record it. That happens inside the worker, which writes
# both config files itself, so nothing in the WebView is on the path and the interface used to find
# out only when it was next restarted. The dialog read the database list once as it opened and never
# again, so a user watching the list watched it stay empty while the database was made underneath it.
#
# The dialog is opened before automatic import is switched on and is never closed, which is what makes
# this test mean something: the entry it ends up showing cannot have come from the read it did as it
# opened, because that read is asserted to have found nothing.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 51 "database-list-live"

# Android only, for the same reason as tests 47 and 48: switching automatic import on needs the photo
# permission granted from outside the app, and the iOS simulator's permission is granted through
# `simctl privacy`, which this machine cannot run or check. Without the permission the app switches
# the setting straight back off and no database is ever created.
if [ "$PLATFORM" != "android" ]; then
    log_info "SKIP: this test needs the photo permission granted from outside the app, which is not available on the iOS simulator here."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

# The name the app lists the database it makes for itself under (DEFAULT_DATABASE_DISPLAY_NAME).
DEFAULT_DATABASE_NAME="My Photos"

# Automatic import is left switched on by this test, and the app's data outlives it on a shared
# emulator, so it is wiped on the way out as well as on the way in. Without this the next thing to
# run on this emulator inherits an app that is importing the whole device library.
on_exit() {
    local exit_code=$?
    stop_app "$APP_PORT" "$TMP_DIR"
    "${PLATFORM}_reset_app_state" >/dev/null 2>&1 || true
    return $exit_code
}
trap on_exit EXIT

# Wipe everything the app has stored on the device, so it starts with no databases and no settings.
# The list being empty when the dialog opens is the first thing this test asserts.
"${PLATFORM}_reset_app_state" || exit 1

# Grant the photo permission from outside the app. The system dialog cannot be tapped by a test, and
# the app's own request resolves straight away once the permission is already held.
"${PLATFORM}_grant_media_permission" || exit 1

# And the notification permission, for the same reason: switching automatic import on starts a
# foreground service, which the platform requires to post an ongoing notification.
"${PLATFORM}_grant_notification_permission" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Open the database dialog first, while there is nothing to list. It stays open for the rest of the
# test: nothing below closes it or opens it again.
send_command "$APP_PORT" menu '{"itemId":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"

# The list is empty. Asserted rather than assumed, because a list that already held the database
# would make the wait at the end of this test pass without anything having been refreshed.
wait_for_value "$APP_PORT" "no-databases-configured" "No databases configured"

# Switch automatic import on through the settings card. The configuration dialog opens over the top
# of the database dialog, which stays mounted and open underneath it.
send_command "$APP_PORT" menu '{"itemId":"open-configuration"}' || exit 1

# The card is waited for by reading it, not by waiting for its "Automatic import settings loaded"
# line. That line is written once, when the card first reads the settings, which happens as the app
# starts rather than when the dialog opens: it is already behind the log cursor by the time this test
# has opened the database dialog, so a wait for it can only time out. The card renders nothing at all
# until the settings are in, so the toggle carrying its label is the state this needs.
wait_for_value "$APP_PORT" "auto-import-toggle" "Automatic import"

send_command "$APP_PORT" click '{"dataId":"auto-import-toggle"}' || exit 1

# The app hands the loop to the native side. The first pass creates the default database and records
# it, both inside the worker.
wait_for_log "$TMP_DIR" "Starting automatic import." || exit 1

# Close the configuration dialog, leaving the database dialog on screen exactly as it was opened.
send_command "$APP_PORT" click '{"dataId":"configuration-dialog-close"}' || exit 1

# The worker says it has recorded the database...
wait_for_log "$TMP_DIR" "Databases changed" 180 || exit 1

# ...and the still-open dialog is now listing it. This is the assertion the whole test is for: no
# command between the dialog opening and here closed it, reopened it, or asked it to refresh.
wait_for_value "$APP_PORT" "database-list-item-0" "$DEFAULT_DATABASE_NAME" 60

check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 51 passed: database-list-live"
