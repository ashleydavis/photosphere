#!/usr/bin/env bash

# Opens the Windows shell's folder in Visual Studio Code. See open-windows.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/windows-common.sh"

code "$WINDOWS_SHELL_DIR"
