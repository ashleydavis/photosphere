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

# The page is bundled into a directory of this build's own and embedded from there, so a build of another platform running at the
# same moment cannot replace it mid-build. Removed afterwards.
FRONTEND_DIR="$(cd "$APP_DIR/../photosphere-frontend" && pwd)"
PAGE_DIR="$(mktemp -d "$FRONTEND_DIR/page.XXXXXX")"
trap 'find "$PAGE_DIR" -type f -delete; find "$PAGE_DIR" -depth -type d -empty -delete' EXIT
(cd "$APP_DIR" && bun run bundle:ui --out-dir "$PAGE_DIR" "${BUNDLE_ARGUMENTS[@]+"${BUNDLE_ARGUMENTS[@]}"}")
(cd "$APP_DIR/../.." && zig build photosphere-linux "-Doptimize=$OPTIMIZE" "-Dstrip=$STRIP" "-Dui-directory=apps/photosphere-frontend/$(basename "$PAGE_DIR")" --prefix "$PREFIX")
echo "Built $PREFIX/bin/photosphere"
