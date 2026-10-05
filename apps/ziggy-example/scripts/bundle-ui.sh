#!/usr/bin/env bash

# Builds the example's page into dist without ever leaving dist half written. See bundle-ui.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$EXAMPLE_DIR/dist"

BUILD_DIR="$(mktemp -d "$EXAMPLE_DIR/dist-build.XXXXXX")"
trap 'find "$BUILD_DIR" -type f -delete; find "$BUILD_DIR" -depth -type d -empty -delete' EXIT

(cd "$EXAMPLE_DIR" && vite build --outDir "$BUILD_DIR" --emptyOutDir)

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
