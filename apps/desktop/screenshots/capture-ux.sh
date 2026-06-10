#!/bin/bash

# Captures screenshots of the Photosphere desktop app's main screens by driving
# the app through its test control server. Used for UX review and documentation.
#
# Run via the package script from the repo root:
#   bun run screenshots
#
# Screenshots are written to ux-review/screenshots/ (gitignored) by default. Set
# OUT_DIR to override. On Linux the app runs headless via xvfb-run (set SHOW_UI=1
# to watch). See docs/testing/screenshots.md for details.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../smoke-tests/lib/common.sh"
DESKTOP_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && pwd)"

OUT_DIR="${OUT_DIR:-$REPO_DIR/ux-review/screenshots}"
TMP_DIR="$TEST_DIR/tmp"
FIXTURE_DB="$REPO_DIR/test/dbs/50-assets"
APP_PORT=$(find_free_port)

rm -rf "$TMP_DIR" "$OUT_DIR"
mkdir -p "$OUT_DIR"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

#
# Captures a screenshot to OUT_DIR/<name>.png after a short settle delay.
# Usage: shot <name> [settle_secs]
#
shot() {
    local name="$1"
    local settle="${2:-1.5}"
    sleep "$settle"
    send_command "$APP_PORT" screenshot "{\"outputPath\":\"$OUT_DIR/$name.png\"}"
    log_info "Captured $name.png"
}

#
# Navigates to an in-app route then captures a screenshot named after it.
# Usage: nav_shot <route> <name> [settle_secs]
#
nav_shot() {
    local route="$1"
    local name="$2"
    local settle="${3:-1.5}"
    send_command "$APP_PORT" navigate "{\"page\":\"$route\"}"
    shot "$name" "$settle"
}

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

# 1. First-run experience: no database loaded.
nav_shot "gallery" "01-startup-no-database" 2

# 2. Open the 50-asset fixture and show the gallery.
send_command "$APP_PORT" open-database "{\"path\":\"$FIXTURE_DB\"}"
wait_for_log "$TMP_DIR" "Gallery loaded: 50 assets"
shot "02-gallery" 2

# 3. Asset detail view. The thumb uses long-press handlers, so a plain DOM
# click is ignored; long-press-click dispatches a real short click that opens
# the asset view.
send_command "$APP_PORT" long-press-click "{\"dataId\":\"gallery-thumb\",\"nth\":0}"
shot "03-asset-detail" 2.5

# 4. Other top-level pages. The right sidebar is captured last because the
# right-sidebar-button only opens it (never toggles closed) and the open panel
# persists across navigation, so it would overlap any page captured afterwards.
nav_shot "gallery" "04-gallery-return" 1
nav_shot "import" "05-import" 1.5
nav_shot "map" "06-map" 2
nav_shot "databases" "07-databases" 1.5

# 5. Add-database dialog.
send_command "$APP_PORT" click "{\"dataId\":\"add-database-button\"}"
shot "08-add-database-dialog" 1.5

nav_shot "secrets" "09-secrets" 1.5
nav_shot "news" "10-news" 1.5
nav_shot "about" "11-about" 1.5
nav_shot "database-summary" "12-database-summary" 1.5

# 6. Left sidebar / navigation menu open.
nav_shot "gallery" "13-gallery" 1
send_command "$APP_PORT" click "{\"dataId\":\"sidebar-toggle-button\"}"
shot "14-left-sidebar" 1.5

# 7. Right sidebar (search / filter / sort panel). Captured last: it opens as a
# persistent overlay that the open button cannot dismiss.
nav_shot "gallery" "15-gallery" 1
send_command "$APP_PORT" click "{\"dataId\":\"right-sidebar-button\"}"
shot "16-right-sidebar" 1.5

log_success "Screenshots written to $OUT_DIR"
ls -1 "$OUT_DIR"
