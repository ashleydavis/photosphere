#!/usr/bin/env bash

# Downloads the pinned WebView2 SDK (and the one mingw-w64 header it needs) into the gitignored webview2-sdk directory.
# See fetch-webview2.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/windows-common.sh"

# The pinned Microsoft.Web.WebView2 NuGet package. The sha256 is of the .nupkg exactly as nuget.org serves it for this
# version, computed with sha256sum when the version was pinned. Change both together.
WEBVIEW2_VERSION="1.0.3856.49"
WEBVIEW2_SHA256="bc0f76eb911b569838dc4aa8f8d325269b966bedb592863d26211aef3a099f1a"
WEBVIEW2_URL="https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$WEBVIEW2_VERSION/microsoft.web.webview2.$WEBVIEW2_VERSION.nupkg"

# WebView2.h includes EventToken.h, a Windows SDK header that Zig's bundled mingw headers do not have. This is the one
# from the mingw-w64 project, at a pinned commit. The sha256 is of the file served by raw.githubusercontent.com.
EVENT_TOKEN_COMMIT="b70f2474437017368c99ca202809f20c4f773855"
EVENT_TOKEN_SHA256="643fdd03bd4f1d8bd0645468bf6f37ccad8b75defe114a2e626b0f85af661260"
EVENT_TOKEN_URL="https://raw.githubusercontent.com/mirror/mingw-w64/$EVENT_TOKEN_COMMIT/mingw-w64-headers/include/eventtoken.h"

DOWNLOAD_DIR="$WINDOWS_SDK_DIR/download"
NUPKG="$DOWNLOAD_DIR/microsoft.web.webview2.$WEBVIEW2_VERSION.nupkg"
EVENT_TOKEN_FILE="$DOWNLOAD_DIR/eventtoken-$EVENT_TOKEN_COMMIT.h"

#
# Downloads a file unless it is already there with the right hash, then fails if the hash is wrong.
# Usage: fetch_verified <url> <file> <sha256>
#
fetch_verified() {
    local url="$1"
    local file="$2"
    local expected="$3"
    if [ ! -f "$file" ]; then
        echo "Downloading $url"
        curl --fail --silent --show-error --location --output "$file" "$url"
    fi
    local actual
    actual="$(sha256sum "$file" | cut -d ' ' -f 1)"
    if [ "$actual" != "$expected" ]; then
        echo "The sha256 of $file is $actual, expected $expected. Delete the file and run again, or check the pin." >&2
        return 1
    fi
}

mkdir -p "$DOWNLOAD_DIR" "$WINDOWS_SDK_DIR/include" "$WINDOWS_SDK_DIR/x64" "$WINDOWS_SDK_DIR/arm64"

fetch_verified "$WEBVIEW2_URL" "$NUPKG" "$WEBVIEW2_SHA256"
fetch_verified "$EVENT_TOKEN_URL" "$EVENT_TOKEN_FILE" "$EVENT_TOKEN_SHA256"

EXTRACT_DIR="$DOWNLOAD_DIR/extracted-$WEBVIEW2_VERSION"
mkdir -p "$EXTRACT_DIR"
windows_unzip "$NUPKG" "$EXTRACT_DIR"

cp "$EXTRACT_DIR/build/native/include/WebView2.h" "$WINDOWS_SDK_DIR/include/WebView2.h"
cp "$EXTRACT_DIR/build/native/include/WebView2EnvironmentOptions.h" "$WINDOWS_SDK_DIR/include/WebView2EnvironmentOptions.h"
cp "$EVENT_TOKEN_FILE" "$WINDOWS_SDK_DIR/include/EventToken.h"
cp "$EXTRACT_DIR/runtimes/win-x64/native/WebView2Loader.dll" "$WINDOWS_SDK_DIR/x64/WebView2Loader.dll"
cp "$EXTRACT_DIR/runtimes/win-arm64/native/WebView2Loader.dll" "$WINDOWS_SDK_DIR/arm64/WebView2Loader.dll"

echo "WebView2 SDK $WEBVIEW2_VERSION is in $WINDOWS_SDK_DIR"
