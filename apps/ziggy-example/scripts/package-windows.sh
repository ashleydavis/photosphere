#!/usr/bin/env bash

# Packages the Windows app as a zip and an NSIS installer, both unsigned. See package-windows.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/windows-common.sh"

arch="x64"
if [ "$#" -gt 0 ]; then
    arch="$1"
fi
windows_zig_target "$arch" > /dev/null

version="$(windows_app_version)"
package_dir="$WINDOWS_SHELL_DIR/package"
prefix="$package_dir/$arch"
artifact_base="ziggy-example-$version-windows-$arch"
mkdir -p "$package_dir"

bash "$WINDOWS_SCRIPTS_DIR/sync-windows.sh" --arch "$arch" --prefix "$prefix" --optimize ReleaseSafe

windows_zip "$package_dir/$artifact_base.zip" "$prefix" "$WINDOWS_APP_DIR_NAME"
echo "Created $package_dir/$artifact_base.zip"

makensis \
    "-DVERSION=$version" \
    "-DARCH=$arch" \
    "-DSOURCE_DIR=$prefix/$WINDOWS_APP_DIR_NAME" \
    "-DOUTPUT_FILE=$package_dir/$artifact_base.exe" \
    "$WINDOWS_SCRIPTS_DIR/package-windows.nsi"
echo "Created $package_dir/$artifact_base.exe"
