#!/usr/bin/env bash

# Sets up what the example's builds need on this machine. See setup.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$(uname -s)" in
    Darwin)
        bash "$SCRIPT_DIR/setup-ios.sh"
        bash "$SCRIPT_DIR/setup-android.sh"
        ;;
    Linux)
        bash "$SCRIPT_DIR/setup-android.sh"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        bash "$SCRIPT_DIR/setup-windows.sh"
        ;;
esac
