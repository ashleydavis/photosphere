#!/bin/bash

# Mobile port of desktop 17-news-notifications. The desktop test feeds a news.yaml via the
# PHOTOSPHERE_NEWS_URL env var (read by the Node main process) and checks the toast lifecycle.
# Mobile has no Node main process to read that env var or fetch a host file, so this port seeds the
# feed through the test driver and checks the toast appears, is dismissed, and does not come back
# after a restart. That last part is what proves the settings the app writes actually reach
# config.yaml in the storage sandbox, which no unit test over an in-memory double can show. Fetching
# a real feed on a device is still follow-up work.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 17 "news-notifications"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's
# localStorage and the keychain) so this test starts from a known state. Done before launch,
# with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Seed a news item (desktop feeds news.yaml via PHOTOSPHERE_NEWS_URL; on mobile the news feed is
# seeded via the test driver). Seeding shows the first unshown item as a toast.
send_command "$APP_PORT" seed-news '{"news":[{"id":"smoke-news-001","message":"Smoke test news item"}]}' || exit 1

wait_for_log "$TMP_DIR" "Showed news notification:"

send_command "$APP_PORT" click '{"dataId":"toast-dismiss"}' || exit 1
wait_for_log "$TMP_DIR" "Marked news notification as shown:"

stop_app "$APP_PORT" "$TMP_DIR"

# What has been shown is recorded in config.yaml in the storage sandbox, written by the WebView
# through the embedded worker, so this is the check that the writing actually reaches the file: after
# a restart the first item must not be announced again. Seeding both items and expecting the second
# is a positive assertion, where waiting to see nothing happen would pass on a stopwatch.
start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" seed-news '{"news":[{"id":"smoke-news-001","message":"Smoke test news item"},{"id":"smoke-news-002","message":"A second smoke test news item"}]}' || exit 1

wait_for_log "$TMP_DIR" "Showed news notification: smoke-news-002"
log_success "The item dismissed before the restart was not announced again"

check_no_errors "$TMP_DIR"

log_success "Test 17 passed: news-notifications"
