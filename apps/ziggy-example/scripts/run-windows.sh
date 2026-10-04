#!/usr/bin/env bash

# Builds the Windows app and runs it. See run-windows.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/windows-common.sh"

bash "$WINDOWS_SCRIPTS_DIR/sync-windows.sh"
exec "$WINDOWS_SHELL_DIR/zig-out/$WINDOWS_APP_DIR_NAME/ziggy-example.exe" "$@"
