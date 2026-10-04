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
    local relative
    rm -f "$app_dir/ziggy-example.exe" "$app_dir/ziggy-example.pdb" "$app_dir/WebView2Loader.dll"
    if [ -d "$WINDOWS_EXAMPLE_DIR/dist" ]; then
        while IFS= read -r relative; do
            rm -f "$app_dir/ui/$relative"
        done < <(cd "$WINDOWS_EXAMPLE_DIR/dist" && find . -type f)
        while IFS= read -r relative; do
            rmdir "$app_dir/ui/$relative" 2> /dev/null || true
        done < <(cd "$WINDOWS_EXAMPLE_DIR/dist" && find . -mindepth 1 -type d | sort -r)
    fi
    rmdir "$app_dir/ui" "$app_dir" 2> /dev/null || true
}

remove_install "$WINDOWS_SHELL_DIR/zig-out/$WINDOWS_APP_DIR_NAME"

version="$(windows_app_version)"
for arch in x64 arm64; do
    remove_install "$WINDOWS_SHELL_DIR/package/$arch/$WINDOWS_APP_DIR_NAME"
    rmdir "$WINDOWS_SHELL_DIR/package/$arch" 2> /dev/null || true
    rm -f "$WINDOWS_SHELL_DIR/package/ziggy-example-$version-windows-$arch.zip"
    rm -f "$WINDOWS_SHELL_DIR/package/ziggy-example-$version-windows-$arch.exe"
done
rmdir "$WINDOWS_SHELL_DIR/package" 2> /dev/null || true
