#!/usr/bin/env bash

# Builds the example's page and its Linux shell, which embeds the page in the executable. See sync-linux.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHELL_DIR="$EXAMPLE_DIR/shells/linux"

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

(cd "$EXAMPLE_DIR" && bun run bundle:ui)
(cd "$EXAMPLE_DIR/../.." && zig build ziggy-example-linux "-Doptimize=$OPTIMIZE" $HOOKS_ARGUMENT --prefix "$SHELL_DIR/zig-out")
