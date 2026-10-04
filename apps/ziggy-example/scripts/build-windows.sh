#!/usr/bin/env bash

# Builds the Windows app. See build-windows.md.

set -euo pipefail

bash "$(dirname "${BASH_SOURCE[0]}")/sync-windows.sh" "$@"
