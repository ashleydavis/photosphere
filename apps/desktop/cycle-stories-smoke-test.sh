#!/bin/bash

#
# Cycle-stories smoke test for the Electron desktop app.
#
# Launches the packaged Electron app in test mode, navigates the renderer to
# /#/stories?cycle=1&duration=<ms>, then waits for the renderer to emit
# "STORIES CYCLE COMPLETE". If any "STORIES CYCLE FAILED:" lines appear in
# the renderer log the test exits non-zero with the failures printed to
# stderr. Otherwise the final completion line is printed and the test exits
# zero.
#
# Usage:
#   ./apps/desktop/cycle-stories-smoke-test.sh                          # default duration 1000ms per story
#   ./apps/desktop/cycle-stories-smoke-test.sh --duration 500           # custom duration
#   ./apps/desktop/cycle-stories-smoke-test.sh --screenshots <dir>      # capture a PNG per story
#   ./apps/desktop/cycle-stories-smoke-test.sh --screenshots <dir> --open  # open index.html when done
#

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP_DIR="$TEST_DIR"
source "$DESKTOP_DIR/smoke-tests/lib/common.sh"

DURATION_MS=1000
#
# Default screenshots location: apps/desktop/stories-screenshots/. Pass
# --screenshots <dir> to override, or --no-screenshots to skip capture entirely.
#
SCREENSHOTS_DIR="$DESKTOP_DIR/stories-screenshots"
OPEN_INDEX=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --duration)
            DURATION_MS="$2"
            shift 2
            ;;
        --screenshots)
            SCREENSHOTS_DIR="$2"
            shift 2
            ;;
        --no-screenshots)
            SCREENSHOTS_DIR=""
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

#
# Resolves a path to an absolute path without requiring the path to exist.
# Portable across linux/mac/win (avoids `realpath -m` which is GNU-only).
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
# Watches app.log for STORIES CYCLE READY lines and, for each one, captures a
# screenshot of the current renderer state then signals the renderer to
# advance to the next story. Exits when the parent process kills it (after
# STORIES CYCLE COMPLETE has been observed by the main script).
#
# Layout under the screenshots directory mirrors the story id:
#   <dir>/<category>/<component>/<variant>.png
# Story ids are already kebab-case with '/' as the separator, so the on-disk
# path mirrors the id directly.
#
capture_loop() {
    local log_file="$1"
    local screenshots_dir="$2"
    local port="$3"

    #
    # Use a bash-side `tail -F` so the loop wakes immediately on each new line.
    # `-n 0` starts at the end of the file so we ignore anything written before
    # the capture loop was started.
    #
    #
    # Each log event is written twice (once by the renderer-log forwarder, once
    # by the [EVENT] formatter), so dedupe by remembering the last story id we
    # processed and skipping repeats. Without this dedupe the loop fires
    # /cycle-advance twice per story, which causes every other story to be
    # skipped because the second advance arrives while the next story is still
    # in its initial settle phase.
    #
    local last_id=""
    tail -F -n 0 "$log_file" 2>/dev/null | while IFS= read -r line; do
        if [[ "$line" == *"STORIES CYCLE READY:"* ]]; then
            #
            # Payload is "<theme>|<category>|<story_id>". The cycle shows each
            # story in light and then dark, so screenshots are split into
            # <dir>/<theme>/<category>/<story_id>.png and the de-dupe key
            # includes the theme so both themes of a story are captured.
            #
            local payload="${line##*STORIES CYCLE READY: }"
            local theme="${payload%%|*}"
            local rest="${payload#*|}"
            local category="${rest%%|*}"
            local story_id="${rest#*|}"
            #
            # Strip any trailing whitespace bash may have picked up from the log.
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
            local out_path="${screenshots_dir}/${theme}/${category}/${story_id}.png"
            #
            # On the first iteration, dump a verbose curl to capture-loop-first.log
            # so we can compare it against the function-body diagnostic (which works).
            #
            #
            # Hit 127.0.0.1 directly instead of going through send_command's
            # `curl -s http://localhost:...`. The test-control-server binds to
            # 127.0.0.1, but `localhost` resolves to both ::1 and 127.0.0.1.
            # In silent mode (`-s`) some curl versions do not fall back to IPv4
            # after an IPv6 "Connection refused", so they exit 7 even though
            # the IPv4 address is reachable.
            #
            local body
            body="{\"outputPath\":\"$(abs_path "$out_path")\"}"
            curl -sS --fail --connect-timeout 5 -X POST "http://127.0.0.1:$port/screenshot" \
                -H "Content-Type: application/json" \
                -d "$body" </dev/null > /dev/null 2>&1 || true
            curl -sS --fail --connect-timeout 5 -X POST "http://127.0.0.1:$port/cycle-advance" \
                -H "Content-Type: application/json" \
                -d '{}' </dev/null > /dev/null 2>&1 || true
        fi
    done
}

#
# Generates a self-contained index.html that lists every captured screenshot
# in a grid grouped by category, with a search box that filters by story id.
#
generate_index() {
    local screenshots_dir="$1"
    local index_path="${screenshots_dir}/index.html"
    local images
    images=$(find "$screenshots_dir" -name "*.png" -type f 2>/dev/null | sort)
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
<title>Photosphere stories</title>
<style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 16px; background: #fafafa; color: #222; }
    h1 { margin: 0 0 12px; font-size: 20px; }
    h2 { margin: 24px 0 8px; font-size: 16px; color: #555; }
    .controls { position: sticky; top: 0; background: #fafafa; padding: 8px 0; border-bottom: 1px solid #eaeaea; margin-bottom: 8px; }
    input[type="search"] { width: 320px; max-width: 100%; padding: 6px 10px; border: 1px solid #ccc; border-radius: 4px; font-size: 14px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 12px; }
    .card { background: white; border: 1px solid #e2e2e2; border-radius: 6px; overflow: hidden; }
    .card img { display: block; width: 100%; height: 180px; object-fit: contain; background: #f4f4f4; cursor: zoom-in; }
    .card .label { padding: 8px 10px; font-size: 12px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; color: #333; word-break: break-all; }
    .hidden { display: none; }
    .empty { color: #999; font-style: italic; margin: 4px 0 0; }
</style>
</head>
<body>
<h1>Photosphere stories</h1>
<div class="controls">
    <input id="filter" type="search" placeholder="Filter by id…" autofocus>
    <span id="counts"></span>
</div>
HTML_HEAD

        local prev_category=""
        local printed_section_open=0
        local total=0
        while IFS= read -r img; do
            local rel="${img#${screenshots_dir}/}"
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
            echo "<div class=\"card\" data-story-id=\"$story_id\"><a href=\"$rel\" target=\"_blank\"><img loading=\"lazy\" src=\"$rel\" alt=\"$story_id\"></a><div class=\"label\">$story_id</div></div>"
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

    log_info "Generated index: $index_path"
}

#
# Generates an index.html that shows each story's light and dark screenshots
# side by side, grouped by category, with a search box that filters by story id.
# Expects screenshots under <dir>/light/... and <dir>/dark/....
#
generate_paired_index() {
    local root_dir="$1"
    local index_path="${root_dir}/index.html"
    #
    # Use the light pass as the canonical list of stories, falling back to dark
    # if only dark was captured.
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
<title>Photosphere stories — light &amp; dark</title>
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
<h1>Photosphere stories — light &amp; dark</h1>
<div class="controls">
    <input id="filter" type="search" placeholder="Filter by id…" autofocus>
    <span id="counts"></span>
</div>
HTML_HEAD

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
# Opens the index.html in the user's default browser. Best-effort across
# linux/mac/win; failure is non-fatal.
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

print_test_header "cycle-stories" "cycle-through-every-story"

#
# Bundle the desktop-frontend and desktop main so Electron has something to load.
# The cycle shows every story in both themes at runtime (via setMode), so a single
# build is enough. Skipped when USE_BINARY=true (the packaged binary is launched).
#
if [ "${USE_BINARY:-false}" != "true" ]; then
    log_info "Bundling desktop-frontend..."
    (cd "$DESKTOP_DIR/../desktop-frontend" && bun run bundle) || exit 1
    log_info "Bundling desktop main..."
    (cd "$DESKTOP_DIR" && bun run bundle) || exit 1
fi

TMP_DIR="$DESKTOP_DIR/cycle-stories-tmp"
rm -rf "$TMP_DIR"
APP_PORT=$(find_free_port)

CAPTURE_PID=""

#
# Kills the capture loop along with its entire descendant tree. The capture
# loop spawns a `tail -F | while read` pipeline whose children (tail, the
# while-subshell) are not killed automatically when the parent dies, so a
# plain `kill $CAPTURE_PID` leaves orphaned `tail -F` processes around.
#
# Strategy:
#   1. Walk descendants depth-first via `pgrep -P` and TERM them.
#   2. TERM the parent itself.
#   3. Brief grace period, then KILL anything that survived.
#
kill_capture_tree() {
    local root_pid="$1"
    if [ -z "$root_pid" ]; then
        return
    fi
    local descendants=""
    collect_descendants() {
        local pid="$1"
        local kids
        kids=$(pgrep -P "$pid" 2>/dev/null || true)
        for kid in $kids; do
            collect_descendants "$kid"
            descendants="$descendants $kid"
        done
    }
    collect_descendants "$root_pid"
    for pid in $descendants "$root_pid"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 0.3
    for pid in $descendants "$root_pid"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
}

cleanup() {
    if [ -n "$CAPTURE_PID" ]; then
        kill_capture_tree "$CAPTURE_PID"
        CAPTURE_PID=""
    fi
    stop_app "$APP_PORT" "$TMP_DIR" || true
}

#
# Run cleanup on normal exit AND on signals. Without INT/TERM here, Ctrl-C
# during the run leaves the tail/while pipeline orphaned.
#
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

if [ -n "$SCREENSHOTS_DIR" ]; then
    rm -rf "$SCREENSHOTS_DIR"
    mkdir -p "$SCREENSHOTS_DIR"
fi

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

#
# Start the capture loop BEFORE navigating so the first READY line is observed
# even if the renderer is fast. The cycle emits the theme in each READY line and
# the capture loop splits screenshots into <dir>/light and <dir>/dark.
#
if [ -n "$SCREENSHOTS_DIR" ]; then
    capture_loop "$TMP_DIR/app.log" "$SCREENSHOTS_DIR" "$APP_PORT" &
    CAPTURE_PID=$!
    log_info "Capture loop started (PID $CAPTURE_PID); screenshots go to $SCREENSHOTS_DIR"
fi

#
# Navigate the renderer to the stories cycle. It walks every story in light and
# then dark, so no theme query param is needed.
#
send_command "$APP_PORT" navigate "{\"page\":\"stories?cycle=1&duration=${DURATION_MS}\"}"

#
# A generous timeout because total wall-clock time grows with the story count,
# now doubled since each story is shown in both themes.
#
wait_for_log "$TMP_DIR" "STORIES CYCLE COMPLETE" 600

#
# Stop the capture loop now that the cycle is complete. tail keeps running
# otherwise.
#
if [ -n "$CAPTURE_PID" ]; then
    kill_capture_tree "$CAPTURE_PID"
    wait "$CAPTURE_PID" 2>/dev/null || true
    CAPTURE_PID=""
fi

failures=$(grep "STORIES CYCLE FAILED:" "$TMP_DIR/app.log" 2>/dev/null || true)
if [ -n "$failures" ]; then
    log_error "Story cycle reported failures:"
    echo "$failures" >&2
    exit 1
fi

#
# Cycle log lines are emitted twice (renderer-log forwarder + [EVENT] formatter)
# so divide the raw count by 2 for the unique total. Each story is rendered once
# per theme, so this counts light + dark renders.
#
ok_count=$(grep -c "STORIES CYCLE OK:" "$TMP_DIR/app.log" 2>/dev/null)
if [ -z "$ok_count" ]; then ok_count=0; fi
unique_ok=$((ok_count / 2))
log_success "Story cycle complete: $unique_ok renders passed (each story in light and dark)"

screenshot_count=0
index_path=""
if [ -n "$SCREENSHOTS_DIR" ]; then
    generate_paired_index "$SCREENSHOTS_DIR"
    index_path="$SCREENSHOTS_DIR/index.html"
    screenshot_count=$(find "$SCREENSHOTS_DIR" -name "*.png" -type f 2>/dev/null | wc -l)
    screenshot_count=${screenshot_count// /}
fi

echo ""
echo "Summary"
echo "  Renders:       $unique_ok passed (each story shown in light and dark)"
if [ -n "$SCREENSHOTS_DIR" ]; then
    echo "  Screenshots:   $screenshot_count → $SCREENSHOTS_DIR"
    echo "  Index:         $index_path"
fi
echo ""

if [ -n "$SCREENSHOTS_DIR" ] && [ "$OPEN_INDEX" = true ] && [ -n "$index_path" ]; then
    open_index "$index_path"
fi

stop_app "$APP_PORT" "$TMP_DIR"
trap - EXIT

exit 0
