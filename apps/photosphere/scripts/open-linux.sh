#!/usr/bin/env bash

# Opens Photosphere's Linux shell project in the editor. See open-linux.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/sync-linux.sh"
code "$SCRIPT_DIR/../shells/linux"
