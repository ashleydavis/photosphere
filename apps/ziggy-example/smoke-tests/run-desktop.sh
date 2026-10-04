#!/usr/bin/env bash

# Runs the Ziggy example's smoke tests on the host operating system. See run-desktop.md.

set -eu

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$(uname -s)" in
    Linux)
        PLATFORM="linux"
        ;;
    Darwin)
        PLATFORM="macos"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        PLATFORM="windows"
        ;;
    *)
        echo "run-desktop.sh: no desktop platform is known for $(uname -s)" >&2
        exit 2
        ;;
esac

exec bash "$SMOKE_DIR/run.sh" "$PLATFORM" "$@"
