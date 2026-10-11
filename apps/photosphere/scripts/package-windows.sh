#!/usr/bin/env bash

# Packages the Windows app as a zip and an MSI installer, both unsigned. See package-windows.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/windows-common.sh"

arch="x64"
version="$(windows_app_version)"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            version="$2"
            shift 2
            ;;
        *)
            arch="$1"
            shift
            ;;
    esac
done
windows_zig_target "$arch" > /dev/null
windows_require_wix

# Windows Installer needs major.minor.build, so a version of any other kind (a nightly) gives the MSI 0.0.0. The file names keep the
# version as given.
msi_version="0.0.0"
if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    msi_version="$version"
fi
package_dir="$WINDOWS_APP_DIR/out/windows"
prefix="$WINDOWS_SHELL_DIR/package/$arch"
artifact_base="photosphere-$version-windows-$arch"
mkdir -p "$package_dir"

bash "$WINDOWS_SCRIPTS_DIR/sync-windows.sh" --arch "$arch" --prefix "$prefix" --optimize ReleaseSafe

windows_zip "$package_dir/$artifact_base.zip" "$prefix" "$WINDOWS_APP_DIR_NAME"
echo "Created $package_dir/$artifact_base.zip"

# candle compiles the installer's description into an object file in the install prefix, and light links it into the MSI.
"$WINDOWS_WIX_DIR/candle.exe" -nologo -arch "$arch" \
    "-dVersion=$msi_version" \
    "-dSourceDir=$prefix/$WINDOWS_APP_DIR_NAME" \
    "-dIconFile=$WINDOWS_APP_DIR/icons/photosphere.ico" \
    -out "$prefix/package-windows.wixobj" \
    "$WINDOWS_SCRIPTS_DIR/package-windows.wxs"
"$WINDOWS_WIX_DIR/light.exe" -nologo -spdb \
    -out "$package_dir/$artifact_base.msi" \
    "$prefix/package-windows.wixobj"
echo "Created $package_dir/$artifact_base.msi"
