#!/bin/bash

# Photosphere iOS frontend smoke tests.
#
# No iOS simulator exists in this environment, so these are build/bundle based,
# not device based. On-device launch (`bun run --filter=ios-frontend run:ios`)
# requires a Mac with Xcode and is performed outside automated CI.
#
# Steps:
#   1. compile (tsc) succeeds.
#   2. bundle (Vite build) produces dist/index.html and a hashed JS bundle.
#   3. the built JS bundle contains the string "Hello world".
#   4. `cap sync ios` succeeds. The native iOS project is generated on macOS
#      (cap add/sync ios runs `pod install`, which needs CocoaPods/macOS), so the
#      web-asset copy is asserted only when ios/ was generated successfully.

set -e

# Absolute path to this script's directory, resolved before any cd takes place.
FRONTEND_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$FRONTEND_DIR"

echo "==> [1/4] Compiling (tsc --noEmit)..."
bun run compile
echo "    compile OK"

echo "==> [2/4] Bundling (vite build)..."
bun run bundle

if [ ! -f "dist/index.html" ]; then
    echo "ERROR: dist/index.html was not produced by the bundle." >&2
    exit 1
fi

JS_BUNDLE="$(find dist/assets -name 'index-*.js' 2>/dev/null | head -n 1)"
if [ -z "$JS_BUNDLE" ]; then
    echo "ERROR: no hashed JS bundle (dist/assets/index-*.js) was produced." >&2
    exit 1
fi
echo "    bundle OK ($JS_BUNDLE)"

echo "==> [3/4] Checking bundle contains 'Hello world'..."
if ! grep -q "Hello world" "$JS_BUNDLE"; then
    echo "ERROR: built JS bundle does not contain 'Hello world'." >&2
    exit 1
fi
echo "    content OK"

echo "==> [4/4] Running 'cap sync ios'..."
bunx cap sync ios

# The web-asset copy target only exists once the native iOS project has been
# generated (macOS/CocoaPods). Assert it conditionally so the smoke test passes
# on Linux where ios/ may not have been generated.
PUBLIC_DIR="ios/App/App/public"
if [ -d "ios/App" ]; then
    if [ ! -f "$PUBLIC_DIR/index.html" ]; then
        echo "ERROR: ios/App exists but web assets were not copied into $PUBLIC_DIR." >&2
        exit 1
    fi
    echo "    sync OK (web assets copied into $PUBLIC_DIR)"
else
    echo "    sync ran; ios/ not generated on this platform (finish 'cap add ios' / 'pod install' on macOS)."
fi

echo ""
echo "All iOS frontend smoke tests passed."
