#!/usr/bin/env bash

# Builds Photosphere's page into apps/photosphere-frontend/dist without ever leaving dist half written. See bundle-ui.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="$(cd "$SCRIPT_DIR/../../photosphere-frontend" && pwd)"
DIST_DIR="$FRONTEND_DIR/dist"

MINIFY_ARGUMENTS=()
OUT_DIR=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --out-dir)
            OUT_DIR="$2"
            shift 2
            ;;
        --minify)
            MINIFY_ARGUMENTS=(--minify esbuild)
            shift
            ;;
        *)
            echo "Unknown argument $1. See bundle-ui.md." >&2
            exit 2
            ;;
    esac
done

# A build of its own: the page goes straight into the directory the build gave, which no other build reads or writes, so builds
# running at the same moment never change each other's page. The smoke tests of two platforms run side by side, and when they shared
# dist, one replaced the page while the other's Zig build was embedding it: "unable to open 'ui-file-9': FileNotFound".
if [ -n "$OUT_DIR" ]; then
    (cd "$FRONTEND_DIR" && bun run bundle --outDir "$OUT_DIR" --emptyOutDir "${MINIFY_ARGUMENTS[@]+"${MINIFY_ARGUMENTS[@]}"}")
    exit 0
fi

BUILD_DIR="$(mktemp -d "$FRONTEND_DIR/dist-build.XXXXXX")"
trap 'find "$BUILD_DIR" -type f -delete; find "$BUILD_DIR" -depth -type d -empty -delete' EXIT

(cd "$FRONTEND_DIR" && bun run bundle --outDir "$BUILD_DIR" --emptyOutDir "${MINIFY_ARGUMENTS[@]+"${MINIFY_ARGUMENTS[@]}"}")

# Other builds running at the same moment read dist (the Zig builds embed it), so dist is left untouched when the page has
# not changed, and a changed file is moved into place whole.
if [ -d "$DIST_DIR" ] && diff -r -q "$BUILD_DIR" "$DIST_DIR" > /dev/null; then
    exit 0
fi
mkdir -p "$DIST_DIR"
NEW_FILES="$(cd "$BUILD_DIR" && find . -type f)"
while IFS= read -r relative; do
    mkdir -p "$DIST_DIR/$(dirname "$relative")"
    mv -f "$BUILD_DIR/$relative" "$DIST_DIR/$relative"
done <<< "$NEW_FILES"

# A file of an earlier build that this one no longer has is deleted.
while IFS= read -r relative; do
    if ! grep -q -x -F "$relative" <<< "$NEW_FILES"; then
        rm -f "$DIST_DIR/$relative"
    fi
done < <(cd "$DIST_DIR" && find . -type f)
