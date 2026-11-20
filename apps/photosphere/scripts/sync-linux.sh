#!/usr/bin/env bash

# Builds Photosphere's page and its Linux native app, which embeds the page in the executable. See sync-linux.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHELL_DIR="$APP_DIR/native/linux"

OPTIMIZE="ReleaseSafe"
PREFIX="$SHELL_DIR/zig-out"
STRIP="false"
BUNDLE_ARGUMENTS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            PREFIX="$2"
            shift 2
            ;;
        --minify)
            BUNDLE_ARGUMENTS=(--minify)
            shift
            ;;
        --strip)
            STRIP="true"
            shift
            ;;
        --optimize)
            OPTIMIZE="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument $1. See sync-linux.md." >&2
            exit 2
            ;;
    esac
done

# The page is bundled into a directory of its own per platform and embedded from there, so a build of another platform
# running at the same moment cannot replace it mid-build. The directory is kept, so a run whose frontend sources have not
# changed reuses the last bundle and the build's cache.
FRONTEND_DIR="$(cd "$APP_DIR/../photosphere-frontend" && pwd)"
PAGE_DIR="$FRONTEND_DIR/page.linux"
ARGUMENTS_STAMP="$PAGE_DIR/.bundle-arguments"
mkdir -p "$PAGE_DIR"
BUNDLE_ARGUMENTS_TEXT="${BUNDLE_ARGUMENTS[*]-}"
REBUILD_PAGE="false"
if [ ! -f "$PAGE_DIR/index.html" ]; then
    REBUILD_PAGE="true"
fi
if [ "$(cat "$ARGUMENTS_STAMP" 2>/dev/null)" != "$BUNDLE_ARGUMENTS_TEXT" ]; then
    REBUILD_PAGE="true"
fi
# The page is built from the frontend and from the workspace packages it imports, where the shared user interface lives, so a
# change to either rebuilds it. Watching the frontend alone left a change to packages/user-interface out of the running app.
if [ -n "$(find "$FRONTEND_DIR/src" "$FRONTEND_DIR/index.html" "$FRONTEND_DIR/vite.config.ts" "$FRONTEND_DIR/package.json" "$APP_DIR/../../packages"/*/src "$APP_DIR/../../packages"/*/package.json "$APP_DIR/../../bun.lock" -newer "$PAGE_DIR/index.html" -print -quit 2>/dev/null)" ]; then
    REBUILD_PAGE="true"
fi
if [ "$REBUILD_PAGE" = "true" ]; then
    (cd "$APP_DIR" && bun run bundle:ui --out-dir "$PAGE_DIR" "${BUNDLE_ARGUMENTS[@]+"${BUNDLE_ARGUMENTS[@]}"}")
    printf '%s' "$BUNDLE_ARGUMENTS_TEXT" > "$ARGUMENTS_STAMP"
fi
# For the baseline CPU, as the other platforms are by naming their target. Built for the machine's own CPU, the release workflow's
# app ran on a smoke test runner with an older CPU and every scenario ended with "Illegal instruction (core dumped)", and a
# package of such a build runs only on CPUs as new as the one it was built on.
(cd "$APP_DIR/../.." && zig build photosphere-linux -Dcpu=baseline "-Doptimize=$OPTIMIZE" "-Dstrip=$STRIP" "-Dui-directory=apps/photosphere-frontend/$(basename "$PAGE_DIR")" --prefix "$PREFIX")
echo "Built $PREFIX/bin/photosphere"
