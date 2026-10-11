#!/usr/bin/env bash

# Packages Photosphere's Linux app as a zip and a deb, without the test hooks. See package-linux.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHELL_DIR="$APP_DIR/shells/linux"
OUTPUT_DIR="$APP_DIR/out/linux"

VERSION="$(jq -r '.version' "$APP_DIR/package.json")"
while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            VERSION="$2"
            shift 2
            ;;
        *)
            echo "package-linux.sh: unknown argument '$1'. Options: --version." >&2
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

(cd "$APP_DIR" && bun run bundle:ui)
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/photosphere-package-XXXXXX")"
(cd "$APP_DIR/../.." && zig build photosphere-linux -Doptimize=ReleaseSafe -p "$STAGE_DIR/prefix")
mkdir -p "$OUTPUT_DIR"

# The zip holds the executable, which has the page embedded, in one folder.
mkdir -p "$STAGE_DIR/zip/photosphere"
cp "$STAGE_DIR/prefix/bin/photosphere" "$STAGE_DIR/zip/photosphere/"
rm -f "$OUTPUT_DIR/$BASE_NAME.zip"
(cd "$STAGE_DIR/zip" && zip -q -r "$OUTPUT_DIR/$BASE_NAME.zip" photosphere)

# The deb installs under /opt, puts a link in /usr/bin and adds a menu entry so the app shows in the applications menu.
mkdir -p "$STAGE_DIR/deb/DEBIAN" "$STAGE_DIR/deb/opt/photosphere" "$STAGE_DIR/deb/usr/bin" "$STAGE_DIR/deb/usr/share/applications" "$STAGE_DIR/deb/usr/share/icons/hicolor/512x512/apps"
cp "$STAGE_DIR/prefix/bin/photosphere" "$STAGE_DIR/deb/opt/photosphere/"
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
