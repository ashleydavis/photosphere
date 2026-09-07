#!/bin/bash

# The date on an imported photo is the date the photo was taken.
#
# Two photos go into the device library: one carrying an EXIF capture date, one carrying none at all.
# Automatic import takes both in, and then the database the app wrote is read back with the CLI and
# the recorded dates are checked.
#
# The rule being tested: the date comes from the photo's own metadata, and failing that from the date
# of the photo itself. Never from the clock, the import or the upload.
#
# It runs on a device because the failure it guards against only exists on one. A photo library item
# is not a file: the import copies it into the app's sandbox first, and that copy is made during the
# import. A photo with no EXIF takes its date from its file, so reading the copy's timestamp dated
# every such photo to the day it was imported, however old it was.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 53 "photo-date"

# Android only, for the same reason test 47 is: there is no supported way to take a seeded photo back
# out of the iOS simulator's library, and a test that leaves one behind poisons every run after it.
if [ "$PLATFORM" != "android" ]; then
    log_info "SKIP: photo dates are covered on Android only. The iOS simulator has no supported way to remove a seeded photo, so this test would leave one behind for every run after it."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

# The photos put into the device library, named so a parallel run cannot collide with them.
DATED_PHOTO_NAME="psphere-photo-date-$$.jpg"
UNDATED_PHOTO_NAME="psphere-photo-date-none-$$.png"

# What test/test.jpg carries in its EXIF. A property of a checked-in fixture, not a figure that goes
# stale.
EXPECTED_PHOTO_DATE="2025-05-27T09:54:16.000Z"

# Where the database is copied to so the CLI can read it.
PULLED_DB_DIR="$TMP_DIR/pulled-db"

# Reads one field out of `psi info` for an asset, empty when the field is absent.
#
# `psi info` prints the stored value rather than a formatted one, so this compares timestamps without
# depending on the machine's locale.
read_asset_field() {
    local asset_id="$1"
    local field_label="$2"
    (cd "$REPO_DIR/apps/cli" && bun run --silent start -- info --db "$PULLED_DB_DIR/photosphere-default" "$asset_id" 2>/dev/null) \
        | grep "$field_label" \
        | head -1 \
        | sed "s/.*$field_label//" \
        | tr -d ' \r'
}

# Everything in the database, newest first.
list_assets() {
    (cd "$REPO_DIR/apps/cli" && bun run --silent start -- list --db "$PULLED_DB_DIR/photosphere-default" --page-size 200 2>/dev/null)
}

# The asset id the database gave the one photo of a given kind.
#
# Found by extension rather than by name, because the record carries the name of the temporary copy
# the import made, which is the library item's id and not the name the photo has in the library.
# That is a separate bug; this works with it rather than depending on it being fixed. Exactly two
# photos are ever in this library, one of each extension.
find_asset_id_by_extension() {
    local extension="$1"
    list_assets | grep -E "^[0-9a-f-]+ .*[.]${extension}\$" | head -1 | awk '{ print $1 }'
}

# Removes the photos from the device library however the test ends, so the next run starts clean.
on_exit() {
    local exit_code=$?
    android_remove_media "$DATED_PHOTO_NAME" 2>/dev/null || true
    android_remove_media "$UNDATED_PHOTO_NAME" 2>/dev/null || true
    stop_app "$APP_PORT" "$TMP_DIR"
    return $exit_code
}
trap on_exit EXIT

# No databases, no settings and no default database: automatic import makes its own, and the photos
# it takes in are the two seeded below and nothing else.
android_reset_app_state || exit 1

# Sweep up anything a killed run left behind, which this run would otherwise import.
android_remove_media_matching "psphere-photo-date-" || true

# This needs a device whose photo library holds nothing but the two photos seeded below.
#
# Automatic import walks the whole library, so a device carrying somebody's real library imports
# thousands of photos and never reaches a state this can read. Said out loud and skipped, because the
# alternative is a timeout that reads like the feature is broken when it is the test that does not
# apply here. Run it against an emulator, where the library is empty.
EXISTING_MEDIA_COUNT="$(adb shell content query --uri content://media/external/images/media --projection _id 2>/dev/null | grep -c '^Row:' || true)"
if [ "${EXISTING_MEDIA_COUNT:-0}" -gt 0 ]; then
    log_info "SKIP: this device's photo library already holds $EXISTING_MEDIA_COUNT item(s), and this test needs one that is empty. Run it against an emulator."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

# A photo with a capture date in it, and a photo with none. Both go in before the app starts, so they
# are part of the library the backfill walks.
#
# The moment either side of the seeding is kept, because the device records a photo's date as the
# moment it entered the library. A photo with no date of its own has to come back with a date inside
# this window: the copy the import makes is minted later, once the app has started and walked the
# library, so a date after the window is the copy's rather than the photo's.
SEEDED_FROM_SECONDS=$(date -u +%s)

android_seed_media "$REPO_DIR/test/test.jpg" "$DATED_PHOTO_NAME" || exit 1
android_seed_media "$REPO_DIR/test/test.png" "$UNDATED_PHOTO_NAME" || exit 1

SEEDED_UNTIL_SECONDS=$(date -u +%s)

android_grant_media_permission || exit 1
android_grant_notification_permission || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Switch automatic import on, which is the only thing the user does.
send_command "$APP_PORT" menu '{"itemId":"open-configuration"}' || exit 1
wait_for_log "$TMP_DIR" "Automatic import settings loaded"
send_command "$APP_PORT" click '{"dataId":"auto-import-toggle"}' || exit 1
wait_for_log "$TMP_DIR" "Starting automatic import." || exit 1

# Both photos have to be in the database before there is anything to read.
#
# Waited for by a pass that recognised both of them before opening either, which is the scanner
# saying it found both already imported. An import reads its source to the end and stops, so the two
# are taken in by separate passes and there is no single line saying "both are in": this is the first
# moment at which that is true.
wait_for_log "$TMP_DIR" '"skippedBeforeOpening":2' 240 || exit 1
log_info "Both photos are in the database"

# Read what the app actually wrote, with the CLI, from outside the app.
android_save_sandbox_dir "photosphere-default" "$PULLED_DB_DIR" || exit 1

# The photo that carries a capture date is recorded with that date, to the second.
DATED_ASSET_ID="$(find_asset_id_by_extension "jpg")"
if [ -z "$DATED_ASSET_ID" ]; then
    log_error "The database has no JPEG asset."
    log_error "Everything the database holds:"
    list_assets | head -20
    exit 1
fi

RECORDED_PHOTO_DATE="$(read_asset_field "$DATED_ASSET_ID" "Photo date: ")"
if [ "$RECORDED_PHOTO_DATE" != "$EXPECTED_PHOTO_DATE" ]; then
    log_error "The photo's date was recorded as \"$RECORDED_PHOTO_DATE\", and its EXIF says \"$EXPECTED_PHOTO_DATE\"."
    log_error "A date close to today means the timestamp of the copy the import made is being recorded instead of the date the photo was taken."
    exit 1
fi
log_info "The photo's date was read from its EXIF: $RECORDED_PHOTO_DATE"

# The photo that carries no date takes the date the device holds for the photo, which is the moment
# it entered the library, so it falls inside the window recorded around the seeding.
#
# This is the assertion the whole test exists for. That date and the copy's timestamp fall on the
# same day here, because the library was seeded moments ago, so comparing against "today" would pass
# either way. What tells them apart is that the copy is made seconds later, after the app has started
# and walked the library, which puts it past the end of the window.
UNDATED_ASSET_ID="$(find_asset_id_by_extension "png")"
if [ -z "$UNDATED_ASSET_ID" ]; then
    log_error "The database has no PNG asset, so the photo carrying no date was not imported."
    log_error "Everything the database holds:"
    list_assets | head -20
    exit 1
fi

UNDATED_PHOTO_DATE="$(read_asset_field "$UNDATED_ASSET_ID" "Photo date: ")"
if [ -z "$UNDATED_PHOTO_DATE" ]; then
    log_error "The photo carrying no EXIF was recorded with no date at all. It should take the date the device holds for the photo."
    exit 1
fi

RECORDED_SECONDS=$(date -u -d "$UNDATED_PHOTO_DATE" +%s 2>/dev/null)
if [ -z "$RECORDED_SECONDS" ]; then
    log_error "The photo carrying no EXIF was recorded with \"$UNDATED_PHOTO_DATE\", which is not a date this test can read."
    exit 1
fi

# A second either side, because the device and this machine round to the second independently.
if [ "$RECORDED_SECONDS" -lt $((SEEDED_FROM_SECONDS - 1)) ] || [ "$RECORDED_SECONDS" -gt $((SEEDED_UNTIL_SECONDS + 1)) ]; then
    log_error "The photo carrying no EXIF was recorded as \"$UNDATED_PHOTO_DATE\" ($RECORDED_SECONDS), and it entered the device library between $SEEDED_FROM_SECONDS and $SEEDED_UNTIL_SECONDS."
    log_error "A later value is the timestamp of the copy the import made, which is minted during the import and is not a date the photo has anything to do with."
    exit 1
fi
log_info "The photo carrying no EXIF took the date the device holds for the photo: $UNDATED_PHOTO_DATE"

# Neither photo may carry the upload time as its date. That is when it went into the database, not
# when it was taken, and it is the other thing the date must never come from.
for asset_id in "$DATED_ASSET_ID" "$UNDATED_ASSET_ID"; do
    photo_date="$(read_asset_field "$asset_id" "Photo date: ")"
    upload_date="$(read_asset_field "$asset_id" "Upload date: ")"
    if [ "$photo_date" = "$upload_date" ]; then
        log_error "Asset $asset_id has the same photo date and upload date (\"$photo_date\"), so the date it was taken is being read from the import."
        exit 1
    fi
done
log_info "Neither photo took its date from the upload"

check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 53 passed: photo-date"
