#!/usr/bin/env bash

# Downloads the pinned WiX Toolset into the gitignored wix directory, for package-windows.sh to build the MSI installer with.
# It needs no installer and no administrator approval. See fetch-wix.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/windows-common.sh"

# The binaries zip of the WiX Toolset 3.14.1 release on GitHub. The sha256 is of the zip as GitHub serves it, computed with
# sha256sum when the version was pinned. WIX_VERSION is in windows-common.sh, because that is where the tools are looked for.
# Change the version, the release tag and the hash together.
WIX_SHA256="6ac824e1642d6f7277d0ed7ea09411a508f6116ba6fae0aa5f2c7daa2ff43d31"
WIX_URL="https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip"

DOWNLOAD_DIR="$WINDOWS_WIX_ROOT/download"
WIX_ZIP="$DOWNLOAD_DIR/wix-$WIX_VERSION-binaries.zip"

mkdir -p "$DOWNLOAD_DIR" "$WINDOWS_WIX_DIR"
fetch_verified "$WIX_URL" "$WIX_ZIP" "$WIX_SHA256"

# The zip has no top level folder: the tools are at its root.
windows_unzip "$WIX_ZIP" "$WINDOWS_WIX_DIR"
windows_require_wix

echo "WiX Toolset $WIX_VERSION is in $WINDOWS_WIX_DIR"
