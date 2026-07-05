#!/usr/bin/env bash
# Runs the iOS native (XCTest) unit tests against whichever iPhone simulator is available, instead of a
# hardcoded model name. The fixed local toolchain (Xcode 14.2 / iOS 16.2 runtime) has no iPhone 15, so a
# hardcoded "iPhone 15" destination fails locally while working on CI; picking an available simulator
# works in both. Prefers an already-booted simulator, then any available iPhone. Building against a
# concrete simulator id (not a generic destination) also builds a single arch matching the single-arch
# bundled media static libraries (vendor/im).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UDID_REGEX="[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"

# The `|| true` on each lookup is required: under `set -euo pipefail` a `grep` that matches nothing
# exits non-zero, which pipefail propagates and errexit would turn into a silent script abort. On CI no
# simulator is booted, so the booted lookup finds nothing and must fall through to the available one.
udid="${IOS_SIMULATOR_UDID:-}"
if [ -z "$udid" ]; then
    udid=$(xcrun simctl list devices booted 2>/dev/null | grep -oE "$UDID_REGEX" | head -1 || true)
fi
if [ -z "$udid" ]; then
    udid=$(xcrun simctl list devices available 2>/dev/null | grep -i 'iPhone' | grep -oE "$UDID_REGEX" | head -1 || true)
fi
if [ -z "$udid" ]; then
    echo "No iOS simulator found. Create an iPhone simulator in Xcode (Window > Devices and Simulators)." >&2
    exit 1
fi

echo "Running iOS unit tests on simulator $udid"
xcodebuild test \
    -workspace "$SCRIPT_DIR/App/App.xcworkspace" \
    -scheme App \
    -destination "id=$udid"
