#!/usr/bin/env bash

# Packages the Windows app as a zip and an MSI installer, both unsigned. See package-windows.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/windows-common.sh"

arch="x64"
output_dir=""
app=""
version="$(windows_app_version)"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output-dir)
            output_dir="$2"
            shift 2
            ;;
        --binary)
            app="$2"
            shift 2
            ;;
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
if [ -n "$output_dir" ]; then
    package_dir="$output_dir"
    # The install prefix goes with the package, so two runs given different directories share nothing.
    prefix="$output_dir/prefix/$arch"
fi
artifact_base="photosphere-$version-windows-$arch"
mkdir -p "$package_dir"

# The app --binary names is packaged as it is, so the release workflow packages the build its app-build job made and smoke tested
# rather than compiling the app a second time. Without it the release build is made here. The installer's object file goes in
# the install prefix either way, so nothing is written into the app given.
mkdir -p "$prefix"
if [ -z "$app" ]; then
    app="$prefix"
    bash "$WINDOWS_SCRIPTS_DIR/sync-windows.sh" --arch "$arch" --prefix "$app" --optimize ReleaseSafe --strip --minify
fi
if [ ! -d "$app/$WINDOWS_APP_DIR_NAME" ]; then
    echo "$app has no $WINDOWS_APP_DIR_NAME directory." >&2
    exit 1
fi

windows_zip "$package_dir/$artifact_base.zip" "$app" "$WINDOWS_APP_DIR_NAME"
echo "Created $package_dir/$artifact_base.zip"

# candle compiles the installer's description into an object file in the install prefix, and light links it into the MSI.
"$WINDOWS_WIX_DIR/candle.exe" -nologo -arch "$arch" \
    "-dVersion=$msi_version" \
    "-dSourceDir=$app/$WINDOWS_APP_DIR_NAME" \
    "-dIconFile=$WINDOWS_APP_DIR/icons/photosphere.ico" \
    -out "$prefix/package-windows.wixobj" \
    "$WINDOWS_SCRIPTS_DIR/package-windows.wxs"
"$WINDOWS_WIX_DIR/light.exe" -nologo -spdb \
    -out "$package_dir/$artifact_base.msi" \
    "$prefix/package-windows.wixobj"
echo "Created $package_dir/$artifact_base.msi"
