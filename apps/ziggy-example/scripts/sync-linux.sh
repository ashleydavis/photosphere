#!/usr/bin/env bash

# Builds the example's page and its Linux shell, and puts the page beside the executable. See sync-linux.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHELL_DIR="$EXAMPLE_DIR/shells/linux"

HOOKS_ARGUMENT=""
if [ "${1:-}" = "--test-hooks" ]; then
    HOOKS_ARGUMENT="-Dtest-hooks=true"
fi

(cd "$EXAMPLE_DIR" && bun run bundle:ui)
(cd "$SHELL_DIR" && zig build $HOOKS_ARGUMENT)
mkdir -p "$SHELL_DIR/zig-out/bin/ui"
cp -R "$EXAMPLE_DIR/dist/." "$SHELL_DIR/zig-out/bin/ui/"
