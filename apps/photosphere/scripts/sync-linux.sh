#!/usr/bin/env bash

# Builds Photosphere's page and its Linux shell, which embeds the page in the executable. See sync-linux.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHELL_DIR="$APP_DIR/native/linux"

OPTIMIZE="ReleaseSafe"
HOOKS_ARGUMENT=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --optimize)
            OPTIMIZE="$2"
            shift 2
            ;;
        --test-hooks)
            HOOKS_ARGUMENT="-Dtest-hooks=true"
            shift
            ;;
        *)
            echo "Unknown argument $1. See sync-linux.md." >&2
            exit 2
            ;;
    esac
done

(cd "$APP_DIR" && bun run bundle:ui)
(cd "$APP_DIR/../.." && zig build photosphere-linux "-Doptimize=$OPTIMIZE" $HOOKS_ARGUMENT --prefix "$SHELL_DIR/zig-out")
