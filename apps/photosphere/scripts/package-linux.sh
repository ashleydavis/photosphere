#!/usr/bin/env bash

# Packages Photosphere's Linux app as a zip and a deb. See package-linux.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHELL_DIR="$APP_DIR/native/linux"
OUTPUT_DIR="$APP_DIR/out/linux"

VERSION="$(jq -r '.version' "$APP_DIR/package.json")"
APP_PREFIX=""
while [ $# -gt 0 ]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --binary)
            APP_PREFIX="$2"
            shift 2
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        *)
            echo "package-linux.sh: unknown argument '$1'. Options: --binary, --output-dir, --version." >&2
            exit 1
            ;;
    esac
done
# A deb version must start with a digit, so a version such as dev-nightly.20260101 is written as 0.0.0~dev-nightly.20260101, which
# sorts before any release. The file names keep the version as given.
DEB_VERSION="$VERSION"
case "$VERSION" in
    [0-9]*)
        ;;
    *)
        DEB_VERSION="0.0.0~$VERSION"
        ;;
esac
ARCHITECTURE="$(uname -m)"
case "$ARCHITECTURE" in
    x86_64)
        DEB_ARCHITECTURE="amd64"
        ;;
    aarch64)
        DEB_ARCHITECTURE="arm64"
        ;;
    *)
        echo "package-linux.sh: no deb architecture is known for $ARCHITECTURE" >&2
        exit 1
        ;;
esac
BASE_NAME="photosphere-$VERSION-linux-$ARCHITECTURE"

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/photosphere-package-XXXXXX")"
# The app --binary names is packaged as it is, so the release workflow packages the build its app-build job made and smoke tested
# rather than compiling the app a second time. Without it the release build is made here.
if [ -z "$APP_PREFIX" ]; then
    APP_PREFIX="$STAGE_DIR/prefix"
    bash "$SCRIPT_DIR/sync-linux.sh" --prefix "$APP_PREFIX" --optimize ReleaseSafe --minify --strip
fi
if [ ! -f "$APP_PREFIX/bin/photosphere" ]; then
    echo "package-linux.sh: $APP_PREFIX has no bin/photosphere." >&2
    exit 1
fi
mkdir -p "$OUTPUT_DIR"

# The zip holds the executable, which has the page embedded, in one folder.
mkdir -p "$STAGE_DIR/zip/photosphere"
cp "$APP_PREFIX/bin/photosphere" "$STAGE_DIR/zip/photosphere/"
rm -f "$OUTPUT_DIR/$BASE_NAME.zip"
(cd "$STAGE_DIR/zip" && zip -q -r "$OUTPUT_DIR/$BASE_NAME.zip" photosphere)

# The deb installs under /opt, puts a link in /usr/bin and adds a menu entry so the app shows in the applications menu.
mkdir -p "$STAGE_DIR/deb/DEBIAN" "$STAGE_DIR/deb/opt/photosphere" "$STAGE_DIR/deb/usr/bin" "$STAGE_DIR/deb/usr/share/applications" "$STAGE_DIR/deb/usr/share/icons/hicolor/512x512/apps"
cp "$APP_PREFIX/bin/photosphere" "$STAGE_DIR/deb/opt/photosphere/"
ln -s /opt/photosphere/photosphere "$STAGE_DIR/deb/usr/bin/photosphere"
cp "$APP_DIR/icons/photosphere-512.png" "$STAGE_DIR/deb/usr/share/icons/hicolor/512x512/apps/au.com.codecapers.photosphere.png"
cat > "$STAGE_DIR/deb/usr/share/applications/au.com.codecapers.photosphere.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Photosphere
Comment=Photo and video management
Exec=/usr/bin/photosphere
Icon=au.com.codecapers.photosphere
Terminal=false
Categories=Utility;
StartupWMClass=au.com.codecapers.photosphere
DESKTOP
cat > "$STAGE_DIR/deb/DEBIAN/control" <<CONTROL
Package: photosphere
Version: $DEB_VERSION
Architecture: $DEB_ARCHITECTURE
Maintainer: Photosphere
Depends: libgtk-3-0, libgdk-pixbuf-2.0-0, libwebkit2gtk-4.1-0, gstreamer1.0-plugins-good, gstreamer1.0-libav
Description: Photosphere app
 Photo and video management built on Ziggy.
CONTROL
rm -f "$OUTPUT_DIR/$BASE_NAME.deb"
dpkg-deb --build --root-owner-group "$STAGE_DIR/deb" "$OUTPUT_DIR/$BASE_NAME.deb"

echo "Packaged $OUTPUT_DIR/$BASE_NAME.zip and $OUTPUT_DIR/$BASE_NAME.deb"
