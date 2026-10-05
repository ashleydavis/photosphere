#!/usr/bin/env bash

# Removes what the Windows scripts installed and packaged. See clean-windows.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/windows-common.sh"

#
# Removes the files an install put in one app directory, one named file at a time, then the directories if they are empty.
# Usage: remove_install <app directory>
#
remove_install() {
    local app_dir="$1"
    rm -f "$app_dir/ziggy-example.exe" "$app_dir/ziggy-example.pdb"
    rmdir "$app_dir" 2> /dev/null || true
}

remove_install "$WINDOWS_SHELL_DIR/zig-out/$WINDOWS_APP_DIR_NAME"

version="$(windows_app_version)"
for arch in x64 arm64; do
    remove_install "$WINDOWS_SHELL_DIR/package/$arch/$WINDOWS_APP_DIR_NAME"
    rm -f "$WINDOWS_SHELL_DIR/package/$arch/package-windows.wixobj"
    rmdir "$WINDOWS_SHELL_DIR/package/$arch" 2> /dev/null || true
    rm -f "$WINDOWS_EXAMPLE_DIR/out/windows/ziggy-example-$version-windows-$arch.zip"
    rm -f "$WINDOWS_EXAMPLE_DIR/out/windows/ziggy-example-$version-windows-$arch.msi"
done
rmdir "$WINDOWS_EXAMPLE_DIR/out/windows" 2> /dev/null || true
