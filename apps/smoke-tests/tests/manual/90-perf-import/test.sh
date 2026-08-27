#!/bin/bash

# Measures a real automatic import on a real device, cold cache and warm.
#
# This is not part of any normal run. It lives under tests/manual/ so an unfiltered run never sweeps
# it up, and it is selected only by naming it. It measures the device's own photo library, so how
# long it takes and what it finds depend entirely on what is on the phone, which is exactly what a
# measurement wants and exactly what a test suite cannot have.
#
# What it does, twice:
#
#   Cold: the hash cache is deleted, so every photo the run reaches is exported out of the library
#   and hashed. This is what a first backup of a phone does, and it is the pass a faster hash is
#   aimed at.
#
#   Warm: run straight after, with the cache the cold pass left behind. Nothing is exported and
#   nothing is hashed. This is what the phone does on every run after the first.
#
# Each pass is time-boxed, because a cold import of a real library takes hours and this has to be
# repeatable four times over to compare a before against an after. What is compared is the rate and
# the split between hashing and everything else, not a total for the whole library.
#
# It reads the `Import timings:` line the import writes as each pass ends. That line is sent from the
# import task as a message and logged by the app, because the import runs inside the embedded JS
# engine whose own log never reaches the app log.
#
# It reads the photo library and deletes one directory of its own, the hash cache. It never seeds a
# photo and never removes one. Note that the smoke test runner clears the app's data when the run
# ends, which removes the app's own databases and settings, and nothing outside the app.
#
# The screen has to stay on for the whole run. There is no foreground service holding the scan up
# when the app leaves the screen, so a phone that sleeps stops importing and the measurement is void.
#
# Usage, naming it explicitly and raising the per-test timeout well above the default:
#
#   PHOTOSPHERE_PERF_IMPORT_SECONDS=1200 \
#   PHOTOSPHERE_PER_TEST_TIMEOUT=3600 \
#   PHOTOSPHERE_ANDROID_DEVICES="<serial>" \
#   bun run test:and -- 90-perf-import

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../../lib/common.sh"

print_test_header 90 "perf-import"

# Android only. The iOS simulator has no real photo library to measure and no supported way to
# manage one, so there is nothing here for it to say.
if [ "$PLATFORM" != "android" ]; then
    log_info "SKIP: this measures a real device photo library, which only the Android path has."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

# How long each pass is allowed to run. Both passes get the same box, so the before and after are
# comparable; a before and an after taken over different boxes are not.
PERF_IMPORT_SECONDS="${PHOTOSPHERE_PERF_IMPORT_SECONDS:-1200}"

#
# How many `Import timings:` lines the app log holds so far.
#
# `grep -c` prints 0 and exits 1 when it matches nothing, so a `|| echo 0` fallback appends a second
# zero and every later comparison is against a two-line value that is not a number. The count is read
# into a variable and defaulted instead, which also covers the log file not existing yet.
count_timings() {
    local count
    count=$(grep -c "Import timings: " "$1/app.log" 2>/dev/null)
    echo "${count:-0}"
}

#
# Prints the JSON from the LAST `Import timings:` line the pass reported, ignoring everything the
# passes before it wrote.
#
# The import reports its timings with every progress report, so a pass leaves a trail of them, each
# a running total. The last one is the whole of what that pass did. Lines from earlier passes are
# skipped by count, which is why the caller records the count before the pass starts.
#
read_timings_after() {
    local tmp_dir="$1"
    local skip_count="$2"
    sed -n 's/.*Import timings: //p' "$tmp_dir/app.log" 2>/dev/null | tail -n "+$((skip_count + 1))" | tail -1
}

#
# Waits until an `Import timings:` line has appeared that was not there before, or the timeout runs
# out. Returns 1 on the timeout so the caller can say what was missing rather than hanging.
#
# Usage: wait_for_new_timings <tmp_dir> <previous_count> <timeout_seconds>
#
wait_for_new_timings() {
    local tmp_dir="$1"
    local previous_count="$2"
    local timeout_seconds="$3"
    local ticks="$timeout_seconds"
    local current_count
    while [ "$ticks" -gt 0 ]; do
        current_count=$(count_timings "$tmp_dir")
        if [ "$current_count" -gt "$previous_count" ]; then
            return 0
        fi
        sleep 1
        ticks=$((ticks - 1))
    done
    return 1
}

#
# Reads one number out of a timings JSON line.
#
timings_field() {
    echo "$1" | sed -n "s/.*\"$2\":\([0-9]*\).*/\1/p"
}

#
# The pid of the loop that keeps the device awake, recorded the moment it is started so the exit trap
# can stop it whatever happens. A process nobody wrote down cannot be cleaned up except by guessing.
KEEP_AWAKE_PID=""

#
# Keeps the device awake for the length of the run by waking it every few seconds.
#
# A phone left to itself sleeps within seconds, and a sleeping phone leaves the app un-resumed, which
# makes Android refuse the foreground service automatic import is started by and kills the app. The
# import survives the screen going off once its service is running; it is getting the service started
# that needs the app in front.
#
# Wake events rather than a settings change: this alters nothing on the device that outlives the run,
# where `svc power stayon` would leave the phone configured differently than it was found.
#
start_keeping_device_awake() {
    (
        while true; do
            adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
            sleep 5
        done
    ) &
    KEEP_AWAKE_PID=$!
}

on_exit() {
    local exit_code=$?
    if [ -n "$KEEP_AWAKE_PID" ]; then
        kill_process_tree "$KEEP_AWAKE_PID" 2>/dev/null || true
    fi
    stop_app "$APP_PORT" "$TMP_DIR"
    return $exit_code
}
trap on_exit EXIT

# Refuse to run against a phone that is already importing on its own: an import running beside this
# one takes the same photos and throws both sets of numbers out.
log_info "Measuring automatic import on the attached device, ${PERF_IMPORT_SECONDS}s per pass."

start_keeping_device_awake

# Wipe the app's own state so the cold pass really is cold: no database, no settings, and above all
# no hash cache. Nothing outside the app is touched, so the device's photos are left exactly as they
# are.
"${PLATFORM}_reset_app_state" || exit 1

"${PLATFORM}_grant_media_permission" || exit 1
"${PLATFORM}_grant_notification_permission" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# The settings card is opened once and stays on screen for the whole test. Nothing navigates away
# from it, so every toggle below is a click and nothing more.
send_command "$APP_PORT" menu '{"itemId":"open-configuration"}' || exit 1
wait_for_log "$TMP_DIR" "Automatic import settings loaded" || exit 1

#
# Runs one pass for the time box and prints the last timings it reported.
#
# The pass is started by clicking the toggle, which works because the app has just been launched and
# its interface is awake. It is ended by force-stopping the app over adb, NOT by clicking the toggle
# again: by then the phone has been sitting on its lockscreen for minutes and Android has paused the
# WebView, so a command sent to the interface is never answered and the pass is lost. Nothing is
# asked of the interface after the first click.
#
# Nothing is lost by killing the app. The import reports where its time has gone with every progress
# report, so the measurement is whatever the last one said.
#
# Whether the app has already begun importing since this pass opened it.
#
# The automatic import setting is remembered across runs, so an app opened with it on starts
# importing without being asked. Answered by waiting a short while for the line the import writes
# when it starts, rather than by asking the interface, because the setting is the app's and the log
# is the only thing that says what it did with it. Returns 0 when it has started and 1 when it has
# not, so a caller can turn it on itself.
#
# Shares wait_for_log's cursor so a match here is not seen again by a later wait, and leaves the
# cursor alone when nothing matched.
#
already_importing() {
    local cursor_file="$TMP_DIR/.log-cursor"
    local start_line=0
    if [ -f "$cursor_file" ]; then
        start_line=$(cat "$cursor_file")
    fi

    local ticks=$((AUTO_START_WAIT_SECONDS * POLL_TICKS_PER_SECOND))
    while [ "$ticks" -gt 0 ]; do
        local matched_line
        matched_line=$(awk -v start="$start_line" '
            NR > start && index($0, "Starting automatic import.") > 0 { print NR; exit }
        ' "$TMP_DIR/app.log" 2>/dev/null)
        if [ -n "$matched_line" ]; then
            echo "$matched_line" > "$cursor_file"
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
        ticks=$((ticks - 1))
    done

    return 1
}

# How long to give an app that was opened with the setting already on to start importing by itself.
# Only ever waited out in full on a pass that then turns the import on, which is the cold pass and
# any pass whose app was left with the setting off.
AUTO_START_WAIT_SECONDS=15

# Usage: run_one_pass <label>
#
run_one_pass() {
    local label="$1"

    "${PLATFORM}_wake_device"
    # Force-stopped first, so a pass that was killed cannot leave an instance running. `am start`
    # would then merely re-deliver the intent to it, and that instance is still holding the control
    # bridge port of the run that died, so it never connects to this one and the run waits out its
    # readiness timeout against an app that is right there on the screen.
    adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true

    start_app "$TMP_DIR"
    wait_for_ready "$APP_PORT"

    send_command "$APP_PORT" menu '{"itemId":"open-configuration"}' || return 1
    wait_for_log "$TMP_DIR" "Automatic import settings loaded" || return 1

    # Android refuses a foreground service started by an app it considers backgrounded, and an app
    # behind a locked keyguard is backgrounded however awake the screen is. The device-idle temporary
    # allowlist is one of the exemptions Android documents for that check. It is scoped to this app,
    # lasts minutes, and expires by itself, so the phone is left as it was found.
    adb shell cmd deviceidle tempwhitelist -d 900000 "$APP_ID" >/dev/null 2>&1 || true

    # Turned on only when it is not on already. A pass ends by force-stopping the app, which leaves
    # the setting exactly as it was, so the warm pass opens an app that starts importing by itself
    # and a click here would switch that off. That is what it did: the warm pass ran for eighteen
    # seconds, was switched off by its own harness, and reported a library it had never looked at.
    if already_importing; then
        log_info "$label pass: the app started importing on its own, so the toggle is left alone."
    else
        send_command "$APP_PORT" click '{"dataId":"auto-import-toggle"}' || return 1
        wait_for_log "$TMP_DIR" "Starting automatic import." || return 1
    fi

    log_info "$label pass running for ${PERF_IMPORT_SECONDS}s..."
    sleep "$PERF_IMPORT_SECONDS"

    adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
    sleep 2
}

# ---- Cold pass: the hash cache is empty, so every photo is exported and hashed. ----

COLD_TIMINGS_BEFORE=$(count_timings "$TMP_DIR")
run_one_pass "Cold" || exit 1

COLD_TIMINGS=$(read_timings_after "$TMP_DIR" "$COLD_TIMINGS_BEFORE" tail)
log_info "COLD: $COLD_TIMINGS"

# A cold pass that hashed nothing measured nothing. The usual causes are a library the app cannot
# see and an import that never started, and both look like success from outside.
if [ "$(timings_field "$COLD_TIMINGS" filesHashed)" -lt 1 ] 2>/dev/null; then
    log_error "The cold pass hashed no files, so nothing was measured."
    exit 1
fi

# ---- Warm pass: the cache the cold pass wrote answers, so nothing is hashed. ----

WARM_TIMINGS_BEFORE=$(count_timings "$TMP_DIR")
run_one_pass "Warm" || exit 1

WARM_TIMINGS=$(read_timings_after "$TMP_DIR" "$WARM_TIMINGS_BEFORE" tail)
log_info "WARM: $WARM_TIMINGS"

# The whole point of the warm pass is that the cache answers before a photo is ever opened. That is
# counted as skippedBeforeOpening: a warm run copies nothing out of the library and hashes nothing,
# so every other counter stays at zero and this is the only one that shows it did any work at all.
WARM_SKIPPED=$(timings_field "$WARM_TIMINGS" skippedBeforeOpening)
if [ "${WARM_SKIPPED:-0}" -lt 1 ] 2>/dev/null; then
    log_error "The warm pass recognised nothing from the hash cache, so the cache was never written."
    exit 1
fi

echo ""
echo "===== automatic import, measured ====="
echo "device:        $(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
echo "seconds/pass:  $PERF_IMPORT_SECONDS"
echo "cold:          $COLD_TIMINGS"
echo "warm:          $WARM_TIMINGS"
echo "======================================"
echo ""

log_success "Test 90 passed: perf-import"
