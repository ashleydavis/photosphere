#!/bin/bash

#
# Story player: plays the live app through every registered story, on any platform.
#
# This is the command-line equivalent of the "Play on automatic" button in the stories browser. It
# launches the app in test mode, navigates it to /#/stories?cycle=1&duration=<ms>, then walks the
# whole story registry (each story in light and then dark), capturing a screenshot per story and
# advancing as soon as the capture is done. It finishes when the app emits "STORIES CYCLE
# COMPLETE". Any "STORIES CYCLE FAILED:" line (a story that crashed while rendering) fails the run.
#
# The three platforms differ only in how the app is built, launched, and screenshotted. Each one
# already has a test harness that exposes the same HTTP command surface (/ready, /navigate,
# /screenshot, /cycle-advance, /quit), so this script drives them all the same way:
#   electron -> apps/desktop/smoke-tests/lib/common.sh  (in-app test control server)
#   android  -> apps/smoke-tests/lib/common.sh          (host control bridge, adb)
#   ios      -> apps/smoke-tests/lib/common.sh          (host control bridge, simctl)
#
# Usage:
#   ./scripts/story-player.sh                              # electron (default)
#   ./scripts/story-player.sh --platform android           # android emulator or attached device
#   ./scripts/story-player.sh --platform ios               # ios simulator
#   ./scripts/story-player.sh --duration 500               # dwell per story (fallback; see below)
#   ./scripts/story-player.sh --screenshots <dir>          # where the PNGs go
#   ./scripts/story-player.sh --no-screenshots             # play only, capture nothing
#   ./scripts/story-player.sh --open                       # open the generated index when done
#   ./scripts/story-player.sh --headless                   # Electron: hide the window (for CI)
#
# The app is VISIBLE by default so you can watch the stories play. Pass --headless to run the
# Electron app under xvfb instead.
#
# Screenshots land in <dir>/<theme>/<category>/<story-id>.png and an index.html is generated at
# the root of <dir> showing each story's light and dark shots side by side.
#

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

#
# The dwell timer is only a fallback: the capture loop advances the cycle as soon as it has taken
# the screenshot, so the dwell never paces a normal run. It MUST comfortably outlast a single
# capture: if it expires first the app advances on its own while the screenshot is still being
# taken, and the capture lands on a later story, silently writing the wrong image under the story's
# name. Screenshotting shells out to adb/simctl on mobile and is occasionally slow (seconds), so
# the fallback there is generous. It only ever costs wall-clock if a capture dies outright.
#
DEFAULT_DURATION_ELECTRON_MS=5000
DEFAULT_DURATION_MOBILE_MS=30000

PLATFORM_NAME="electron"
DURATION_MS=""
SCREENSHOTS_DIR=""
NO_SCREENSHOTS=false
OPEN_INDEX=false
HEADLESS=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --platform)
            PLATFORM_NAME="$2"
            shift 2
            ;;
        --headless)
            HEADLESS=true
            shift
            ;;
        --duration)
            DURATION_MS="$2"
            shift 2
            ;;
        --screenshots)
            SCREENSHOTS_DIR="$2"
            shift 2
            ;;
        --no-screenshots)
            NO_SCREENSHOTS=true
            shift
            ;;
        --open)
            OPEN_INDEX=true
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

case "$PLATFORM_NAME" in
    electron|android|ios)
        ;;
    *)
        echo "Unknown platform: $PLATFORM_NAME (expected electron, android, or ios)" >&2
        exit 2
        ;;
esac

#
# Load the platform's test harness. Both harnesses define the same helpers with the same
# signatures (start_app, wait_for_ready, send_command, wait_for_log, stop_app),
# which is what lets the rest of this script be platform-neutral.
#
if [ "$PLATFORM_NAME" = "electron" ]; then
    DESKTOP_DIR="$REPO_DIR/apps/desktop"
    source "$DESKTOP_DIR/smoke-tests/lib/common.sh"
else
    # common.sh reads PLATFORM to pick its launcher (android.sh or ios.sh).
    export PLATFORM="$PLATFORM_NAME"
    source "$REPO_DIR/apps/smoke-tests/lib/common.sh"
fi

if [ -z "$DURATION_MS" ]; then
    if [ "$PLATFORM_NAME" = "electron" ]; then
        DURATION_MS="$DEFAULT_DURATION_ELECTRON_MS"
    else
        DURATION_MS="$DEFAULT_DURATION_MOBILE_MS"
    fi
fi

#
# Seconds to wait after a story reports READY before grabbing the screen. Only the mobile platforms
# need it: they capture the device framebuffer from outside the app, so the compositor can still be
# showing the previous story. See the capture loop for the failure this prevents.
#
if [ "$PLATFORM_NAME" = "electron" ]; then
    CAPTURE_SETTLE_SECS=0
else
    CAPTURE_SETTLE_SECS=1
fi

#
# The point of the story player is to LOOK at the UI, so the app is visible by default and
# --headless opts out (the opposite of the smoke tests, which are headless by default because
# nobody watches them). On Electron the desktop harness reads SHOW_UI; on Android and iOS the
# emulator/simulator window is always visible, so --headless has nothing to turn off there.
#
if [ "$HEADLESS" = true ]; then
    export SHOW_UI=0
else
    export SHOW_UI=1
fi

if [ "$NO_SCREENSHOTS" = true ]; then
    SCREENSHOTS_DIR=""
elif [ -z "$SCREENSHOTS_DIR" ]; then
    SCREENSHOTS_DIR="$REPO_DIR/stories-screenshots/$PLATFORM_NAME"
fi

TMP_DIR="$REPO_DIR/stories-tmp/$PLATFORM_NAME"

#
# Builds (and for mobile, installs) the app under test. Electron bundles the renderer and main
# process; the mobile platforms boot their emulator/simulator, build the native app, and install
# it. The cycle switches theme at runtime, so one build covers both light and dark.
#
build_app() {
    if [ "$PLATFORM_NAME" = "electron" ]; then
        # A packaged binary (USE_BINARY=true) is already built, so there is nothing to bundle.
        if [ "${USE_BINARY:-false}" = "true" ]; then
            return 0
        fi
        log_info "Bundling desktop-frontend..."
        (cd "$REPO_DIR/apps/desktop-frontend" && bun run bundle) || return 1
        log_info "Bundling desktop main..."
        (cd "$DESKTOP_DIR" && bun run bundle) || return 1
        return 0
    fi

    "${PLATFORM_NAME}_prepare" || return 1
    "${PLATFORM_NAME}_build" || return 1
    "${PLATFORM_NAME}_install" || return 1

    #
    # Seed the 50-assets fixture into the app sandbox, exactly as the mobile smoke tests seed their
    # own fixtures. The stories that show real media open `test/dbs/50-assets` through the REST API;
    # on a device that database only exists if it is copied there first. Without this the app has no
    # such database to serve and those stories report the REST API as unreachable.
    #
    log_info "Seeding the 50-assets fixture into the app sandbox..."
    "${PLATFORM_NAME}_seed_database" "$REPO_DIR/test/dbs/50-assets" "test/dbs/50-assets" || return 1
}

#
# Resolves a path to an absolute path without requiring the path to exist. Portable across
# linux/mac/win (avoids `realpath -m`, which is GNU-only).
#
abs_path() {
    local target="$1"
    if [[ "$target" = /* ]]; then
        echo "$target"
    else
        echo "$(pwd)/$target"
    fi
}

#
# Watches app.log for STORIES CYCLE READY lines and, for each one, captures a screenshot of the
# current story then tells the app to advance to the next one. Runs until the parent kills it
# (after STORIES CYCLE COMPLETE has been observed by the main script).
#
# Screenshots are written to <dir>/<theme>/<category>/<story-id>.png. Story ids are already
# kebab-case with '/' as the separator, so the on-disk path mirrors the id directly.
#
capture_loop() {
    local log_file="$1"
    local screenshots_dir="$2"
    local port="$3"

    #
    # `tail -F` so the loop wakes on each new line; `-n 0` starts at the end of the file so lines
    # written before the loop started are ignored.
    #
    # Electron writes each cycle event to app.log twice (once by the renderer-log forwarder, once
    # by the [EVENT] formatter) while the mobile bridge writes it once, so dedupe on the last
    # story handled. Without the dedupe the loop advances twice per story on Electron, which skips
    # every other story (the second advance lands while the next story is still settling).
    #
    local last_id=""
    tail -F -n 0 "$log_file" 2>/dev/null | while IFS= read -r line; do
        if [[ "$line" == *"STORIES CYCLE READY:"* ]]; then
            #
            # Payload is "<theme>|<category>|<story-id>". The cycle shows each story in light and
            # then dark, so the theme is part of both the output path and the dedupe key.
            #
            local payload="${line##*STORIES CYCLE READY: }"
            local theme="${payload%%|*}"
            local rest="${payload#*|}"
            local category="${rest%%|*}"
            local story_id="${rest#*|}"
            #
            # Strip any trailing whitespace picked up from the log line.
            #
            theme="${theme%%[[:space:]]*}"
            category="${category%%[[:space:]]*}"
            story_id="${story_id%%[[:space:]]*}"
            if [ -z "$theme" ] || [ -z "$category" ] || [ -z "$story_id" ]; then
                continue
            fi
            local dedup_key="${theme}|${story_id}"
            if [ "$dedup_key" = "$last_id" ]; then
                continue
            fi
            last_id="$dedup_key"

            #
            # Let the device repaint before capturing. The app emits READY as soon as React has
            # rendered the story, but on a device the screen is captured from OUTSIDE the app
            # (adb/simctl grab the framebuffer), and the compositor can still be showing the
            # previous story's frame at that moment. Without this wait the capture silently saves
            # the PREVIOUS story's screen under this story's name, which is worse than no
            # screenshot because it looks real. Electron screenshots from inside the renderer, so
            # it needs no wait.
            #
            if [ "$CAPTURE_SETTLE_SECS" != "0" ]; then
                sleep "$CAPTURE_SETTLE_SECS"
            fi

            #
            # Hit 127.0.0.1 directly rather than `localhost`: both harnesses bind loopback IPv4,
            # but `localhost` also resolves to ::1, and in silent mode some curl versions do not
            # fall back to IPv4 after an IPv6 "connection refused".
            #
            local out_path
            out_path="$(abs_path "${screenshots_dir}/${theme}/${category}/${story_id}.png")"
            #
            # These requests are fatal on failure, not swallowed. A dropped /screenshot leaves a
            # gap the paired index silently omits, and a dropped /cycle-advance stalls the whole
            # cycle. Exiting kills this backgrounded capture loop, so no further screenshots are
            # written and the `screenshot_count > 0` assertion at the end of the run fails loudly.
            #
            if ! curl -sS --fail --connect-timeout 5 -X POST "http://127.0.0.1:$port/screenshot" \
                -H "Content-Type: application/json" \
                -d "{\"outputPath\":\"$out_path\"}" </dev/null > /dev/null 2>&1; then
                log_error "Screenshot request failed for story $story_id ($theme)"
                exit 1
            fi
            if ! curl -sS --fail --connect-timeout 5 -X POST "http://127.0.0.1:$port/cycle-advance" \
                -H "Content-Type: application/json" \
                -d '{}' </dev/null > /dev/null 2>&1; then
                log_error "Cycle-advance request failed after story $story_id ($theme)"
                exit 1
            fi
        fi
    done
}

#
# Generates an index.html that shows each story's light and dark screenshots side by side, grouped
# by category, with a search box that filters by story id. Expects screenshots under <dir>/light/
# and <dir>/dark/.
#
generate_paired_index() {
    local root_dir="$1"
    local index_path="${root_dir}/index.html"
    #
    # Use the light pass as the canonical list of stories, falling back to dark if only dark was
    # captured.
    #
    local list_dir="${root_dir}/light"
    if [ ! -d "$list_dir" ]; then
        list_dir="${root_dir}/dark"
    fi
    local images
    images=$(cd "$list_dir" 2>/dev/null && find . -name "*.png" -type f | sort)
    if [ -z "$images" ]; then
        log_info "No screenshots captured; skipping index generation."
        return
    fi

    {
        cat <<'HTML_HEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Photosphere stories &mdash; light &amp; dark</title>
<style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 16px; background: #fafafa; color: #222; }
    h1 { margin: 0 0 12px; font-size: 20px; }
    h2 { margin: 24px 0 8px; font-size: 16px; color: #555; }
    .controls { position: sticky; top: 0; background: #fafafa; padding: 8px 0; border-bottom: 1px solid #eaeaea; margin-bottom: 8px; z-index: 1; }
    input[type="search"] { width: 320px; max-width: 100%; padding: 6px 10px; border: 1px solid #ccc; border-radius: 4px; font-size: 14px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(360px, 1fr)); gap: 12px; }
    .card { background: white; border: 1px solid #e2e2e2; border-radius: 6px; overflow: hidden; }
    .pair { display: grid; grid-template-columns: 1fr 1fr; gap: 1px; background: #e2e2e2; }
    .pair figure { margin: 0; }
    .pair figcaption { font-size: 10px; text-align: center; padding: 2px; color: #666; text-transform: uppercase; letter-spacing: 0.05em; }
    .pair img { display: block; width: 100%; height: 200px; object-fit: contain; cursor: zoom-in; }
    .pair .light img { background: #f4f4f4; }
    .pair .dark img { background: #111; }
    .card .label { padding: 8px 10px; font-size: 12px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; color: #333; word-break: break-all; }
    .hidden { display: none; }
    .empty { color: #999; font-style: italic; margin: 4px 0 0; }
</style>
</head>
<body>
HTML_HEAD

        echo "<h1>Photosphere stories &mdash; ${PLATFORM_NAME} &mdash; light &amp; dark</h1>"
        cat <<'HTML_CONTROLS'
<div class="controls">
    <input id="filter" type="search" placeholder="Filter by id…" autofocus>
    <span id="counts"></span>
</div>
HTML_CONTROLS

        local prev_category=""
        local printed_section_open=0
        local total=0
        while IFS= read -r img; do
            local rel="${img#./}"
            local category="${rel%%/*}"
            local story_id="${rel#*/}"
            story_id="${story_id%.png}"
            if [ "$category" != "$prev_category" ]; then
                if [ "$printed_section_open" -eq 1 ]; then
                    echo "</div></section>"
                fi
                echo "<section data-category=\"$category\"><h2>$category</h2><div class=\"grid\">"
                printed_section_open=1
                prev_category="$category"
            fi
            echo "<div class=\"card\" data-story-id=\"$story_id\"><div class=\"pair\"><figure class=\"light\"><a href=\"light/$rel\" target=\"_blank\"><img loading=\"lazy\" src=\"light/$rel\" alt=\"$story_id light\"></a><figcaption>light</figcaption></figure><figure class=\"dark\"><a href=\"dark/$rel\" target=\"_blank\"><img loading=\"lazy\" src=\"dark/$rel\" alt=\"$story_id dark\"></a><figcaption>dark</figcaption></figure></div><div class=\"label\">$story_id</div></div>"
            total=$((total + 1))
        done <<< "$images"
        if [ "$printed_section_open" -eq 1 ]; then
            echo "</div></section>"
        fi

        cat <<HTML_FOOT
<p class="empty hidden" id="nomatch">No stories match.</p>
<script>
const input = document.getElementById('filter');
const cards = Array.from(document.querySelectorAll('.card'));
const sections = Array.from(document.querySelectorAll('section'));
const counts = document.getElementById('counts');
const nomatch = document.getElementById('nomatch');
const totalCount = ${total};

function applyFilter() {
    const term = input.value.trim().toLowerCase();
    let visible = 0;
    for (const card of cards) {
        const id = card.dataset.storyId.toLowerCase();
        const show = !term || id.includes(term);
        card.classList.toggle('hidden', !show);
        if (show) visible++;
    }
    for (const section of sections) {
        const anyVisible = section.querySelector('.card:not(.hidden)');
        section.classList.toggle('hidden', !anyVisible);
    }
    nomatch.classList.toggle('hidden', visible !== 0);
    counts.textContent = '  ' + visible + ' / ' + totalCount;
}
input.addEventListener('input', applyFilter);
applyFilter();
</script>
</body>
</html>
HTML_FOOT
    } > "$index_path"

    log_info "Generated paired index: $index_path"
}

#
# Opens the index.html in the default browser. Best-effort across linux/mac/win; failure is
# non-fatal.
#
open_index() {
    local index_path="$1"
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$index_path" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then
        open "$index_path" >/dev/null 2>&1 &
    elif command -v start >/dev/null 2>&1; then
        start "" "$index_path" >/dev/null 2>&1 &
    else
        log_info "No browser opener found; open $index_path manually."
    fi
}

print_test_header "story-player" "play-every-story ($PLATFORM_NAME)"

build_app || exit 1

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

CAPTURE_PID=""

cleanup() {
    # The capture loop spawns a `tail -F | while read` pipeline whose children are not killed when
    # the parent dies, so a plain `kill $CAPTURE_PID` leaves an orphaned `tail -F` behind. The tree
    # walk takes the pipeline with it.
    if [ -n "$CAPTURE_PID" ]; then
        kill_process_tree "$CAPTURE_PID"
        CAPTURE_PID=""
    fi
    stop_app "$APP_PORT" "$TMP_DIR" || true

    #
    # Clear the app's data from the device. A mobile run seeds the 50-assets fixture into the app's
    # storage sandbox; left there, run after run, it fills the device until the next install fails.
    #
    if [ "$PLATFORM_NAME" != "electron" ]; then
        "${PLATFORM_NAME}_cleanup" || true
    fi
}

#
# Clean up on normal exit AND on signals. Without INT/TERM here, Ctrl-C during a run leaves the
# tail/while pipeline orphaned.
#
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

if [ -n "$SCREENSHOTS_DIR" ]; then
    rm -rf "$SCREENSHOTS_DIR"
    mkdir -p "$SCREENSHOTS_DIR"
fi

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

#
# Start the capture loop BEFORE navigating so the first READY line is seen even if the app is
# quick off the mark.
#
if [ -n "$SCREENSHOTS_DIR" ]; then
    capture_loop "$TMP_DIR/app.log" "$SCREENSHOTS_DIR" "$APP_PORT" &
    CAPTURE_PID=$!
    log_info "Capture loop started (PID $CAPTURE_PID); screenshots go to $SCREENSHOTS_DIR"
fi

#
# Navigate to the stories cycle. It walks every story in light and then dark, so there is no theme
# to pass here.
#
send_command "$APP_PORT" navigate "{\"page\":\"stories?cycle=1&duration=${DURATION_MS}\"}"

#
# A generous timeout: total wall-clock grows with the story count (doubled, since each story is
# shown in both themes) and mobile capture is slower than desktop.
#
wait_for_log "$TMP_DIR" "STORIES CYCLE COMPLETE" 900

#
# Stop the capture loop now the cycle is done; otherwise `tail` keeps running.
#
if [ -n "$CAPTURE_PID" ]; then
    kill_process_tree "$CAPTURE_PID"
    wait "$CAPTURE_PID" 2>/dev/null || true
    CAPTURE_PID=""
fi

failures=$(grep "STORIES CYCLE FAILED:" "$TMP_DIR/app.log" 2>/dev/null || true)
if [ -n "$failures" ]; then
    log_error "Story player reported failures:"
    echo "$failures" >&2
    exit 1
fi

#
# Take the pass/fail totals from the app's own completion line ("STORIES CYCLE COMPLETE: N passed,
# M failed") rather than counting log lines, because Electron logs each event twice and mobile logs
# it once. Each story is rendered once per theme, so these count light + dark renders.
#
complete_line=$(grep "STORIES CYCLE COMPLETE:" "$TMP_DIR/app.log" 2>/dev/null | tail -1)
renders=$(echo "$complete_line" | sed -n 's/.*COMPLETE: \([0-9]*\) passed.*/\1/p')
if [ -z "$renders" ]; then
    renders=0
fi
log_success "Story player finished on $PLATFORM_NAME: $renders renders passed (each story in light and dark)"

screenshot_count=0
index_path=""
if [ -n "$SCREENSHOTS_DIR" ]; then
    generate_paired_index "$SCREENSHOTS_DIR"
    index_path="$SCREENSHOTS_DIR/index.html"
    screenshot_count=$(find "$SCREENSHOTS_DIR" -name "*.png" -type f 2>/dev/null | wc -l)
    screenshot_count=${screenshot_count// /}
    #
    # A run that requested screenshots but captured none is a failure, not a pass: the capture loop
    # never fired (or died on a fatal /screenshot request above). Assert this rather than merely
    # reporting the count, so an empty run cannot exit 0 and look successful.
    #
    if [ "$screenshot_count" -eq 0 ]; then
        log_error "No screenshots were captured under $SCREENSHOTS_DIR (expected at least one)"
        exit 1
    fi
fi

echo ""
echo "Summary"
echo "  Platform:      $PLATFORM_NAME"
echo "  Renders:       $renders passed (each story shown in light and dark)"
if [ -n "$SCREENSHOTS_DIR" ]; then
    echo "  Screenshots:   $screenshot_count → $SCREENSHOTS_DIR"
    echo "  Index:         $index_path"
fi
echo ""

if [ -n "$SCREENSHOTS_DIR" ] && [ "$OPEN_INDEX" = true ] && [ -n "$index_path" ]; then
    open_index "$index_path"
fi

#
# The same teardown the traps use: stop the app and clear its data from the device. Calling cleanup
# here (rather than just stop_app) is what makes a successful run leave the device as it found it;
# the trap is then removed so it does not run a second time.
#
cleanup
trap - EXIT

exit 0
