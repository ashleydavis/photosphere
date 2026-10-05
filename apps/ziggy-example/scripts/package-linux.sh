#!/usr/bin/env bash

# Packages the example's Linux app as a zip and a deb, without the test hooks. See package-linux.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHELL_DIR="$EXAMPLE_DIR/shells/linux"
OUTPUT_DIR="$EXAMPLE_DIR/out/linux"

VERSION="$(jq -r '.version' "$EXAMPLE_DIR/package.json")"
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
BASE_NAME="ziggy-example-$VERSION-linux-$ARCHITECTURE"

(cd "$EXAMPLE_DIR" && bun run bundle:ui)
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ziggy-example-package-XXXXXX")"
(cd "$SHELL_DIR" && zig build -Doptimize=ReleaseSafe -p "$STAGE_DIR/prefix")
mkdir -p "$OUTPUT_DIR"

# The zip holds the executable, which has the page embedded, in one folder.
mkdir -p "$STAGE_DIR/zip/ziggy-example"
cp "$STAGE_DIR/prefix/bin/ziggy-example" "$STAGE_DIR/zip/ziggy-example/"
rm -f "$OUTPUT_DIR/$BASE_NAME.zip"
(cd "$STAGE_DIR/zip" && zip -q -r "$OUTPUT_DIR/$BASE_NAME.zip" ziggy-example)

# The deb installs under /opt, puts a link in /usr/bin and adds a menu entry so the app shows in the applications menu.
mkdir -p "$STAGE_DIR/deb/DEBIAN" "$STAGE_DIR/deb/opt/ziggy-example" "$STAGE_DIR/deb/usr/bin" "$STAGE_DIR/deb/usr/share/applications"
cp "$STAGE_DIR/prefix/bin/ziggy-example" "$STAGE_DIR/deb/opt/ziggy-example/"
ln -s /opt/ziggy-example/ziggy-example "$STAGE_DIR/deb/usr/bin/ziggy-example"
cat > "$STAGE_DIR/deb/usr/share/applications/dev.ziggy.example.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Ziggy example
Comment=A small complete app built on Ziggy
Exec=/usr/bin/ziggy-example
Terminal=false
Categories=Utility;
StartupWMClass=dev.ziggy.example
DESKTOP
cat > "$STAGE_DIR/deb/DEBIAN/control" <<CONTROL
Package: ziggy-example
Version: $VERSION
Architecture: $DEB_ARCHITECTURE
Maintainer: Ziggy
Depends: libgtk-3-0, libwebkit2gtk-4.1-0
Description: The Ziggy example app
 A small complete app built on Ziggy.
CONTROL
rm -f "$OUTPUT_DIR/$BASE_NAME.deb"
dpkg-deb --build --root-owner-group "$STAGE_DIR/deb" "$OUTPUT_DIR/$BASE_NAME.deb"

echo "Packaged $OUTPUT_DIR/$BASE_NAME.zip and $OUTPUT_DIR/$BASE_NAME.deb"
