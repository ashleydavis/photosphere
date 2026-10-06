#!/usr/bin/env bash

# A value the page writes to localStorage and to IndexedDB is still there after the app is quit and started again, so the web
# view keeps the page's storage between runs.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app

click storage-read
wait_for_text storage-status "localStorage: none; indexedDB: none"

click storage-write
wait_for_text storage-status "written"

# Android's web view writes localStorage to disk a few seconds after the page sets it, so a kill sooner than that loses it.
# IndexedDB is written at once. The wait lets the delayed write happen, as it does when a person uses the app and then leaves it.
sleep 8
restart_test_app

click storage-read
wait_for_text storage-status "localStorage: kept é 世界 😀; indexedDB: kept é 世界 😀"
