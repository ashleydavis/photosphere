#!/usr/bin/env bash

# Packages the Windows app as a zip and an MSI installer, both unsigned. See package-windows.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/windows-common.sh"

arch="x64"
if [ "$#" -gt 0 ]; then
    arch="$1"
fi
windows_zig_target "$arch" > /dev/null
windows_require_wix

version="$(windows_app_version)"
package_dir="$WINDOWS_EXAMPLE_DIR/out/windows"
artifact_base="ziggy-example-$version-windows-$arch"
mkdir -p "$package_dir"

# The app is built into a temporary prefix, as package-linux.sh does, so that out/windows holds only the packages.
prefix="$(mktemp -d "${TMPDIR:-/tmp}/ziggy-example-package-XXXXXX")"
if [ "$WINDOWS_HOST" = "1" ]; then
    prefix="$(cd "$prefix" && pwd -W)"
fi

bash "$WINDOWS_SCRIPTS_DIR/sync-windows.sh" --arch "$arch" --prefix "$prefix" --optimize ReleaseSafe

windows_zip "$package_dir/$artifact_base.zip" "$prefix" "$WINDOWS_APP_DIR_NAME"
echo "Created $package_dir/$artifact_base.zip"

# candle compiles the installer's description into an object file in the temporary prefix, and light links it into the MSI.
"$WINDOWS_WIX_DIR/candle.exe" -nologo -arch "$arch" \
    "-dVersion=$version" \
    "-dSourceDir=$prefix/$WINDOWS_APP_DIR_NAME" \
    -out "$prefix/package-windows.wixobj" \
    "$WINDOWS_SCRIPTS_DIR/package-windows.wxs"
"$WINDOWS_WIX_DIR/light.exe" -nologo -spdb \
    -out "$package_dir/$artifact_base.msi" \
    "$prefix/package-windows.wixobj"
echo "Created $package_dir/$artifact_base.msi"
