#!/usr/bin/env bash

# Builds the Photosphere Android app and uploads it to Firebase App Distribution, which notifies the tester group and gives
# them a link to install it. See distribute-android.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$APP_DIR/../.." && pwd)"

# The Firebase project the Photosphere apps are in, from the Firebase console under Project settings > General. It is an
# identifier and not a secret.
FIREBASE_PROJECT="photosphere-84761"

# The Photosphere App's Android package name, which is how its Firebase app is found, and the name that app is given when it has to
# be created.
APP_PACKAGE_NAME="au.com.codecapers.photosphere.ziggy"
APP_DISPLAY_NAME="Photosphere (Ziggy)"

TESTER_GROUPS="testers"
BUILD_ONLY="false"
APP_VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --version-name)
            APP_VERSION="$2"
            shift 2
            ;;
        --groups)
            TESTER_GROUPS="$2"
            shift 2
            ;;
        --project)
            FIREBASE_PROJECT="$2"
            shift 2
            ;;
        --build-only)
            BUILD_ONLY="true"
            shift
            ;;
        *)
            echo "ERROR: unknown argument '$1'. Options: --groups, --project, --version-name, --build-only." >&2
            exit 1
            ;;
    esac
done

# Checked before the build rather than after it, so a missing tool costs a second instead of a full build.
for tool in jq; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "ERROR: $tool is not on your PATH." >&2
        exit 1
    fi
done
if [ "$BUILD_ONLY" = "false" ] && ! command -v firebase > /dev/null 2>&1; then
    echo "ERROR: the Firebase CLI is not on your PATH." >&2
    echo "Install it with 'curl -sL https://firebase.tools | bash', then run 'firebase login'." >&2
    exit 1
fi

# The newest commits only, because Firebase App Distribution rejects long release notes, and does it after the whole APK has
# been uploaded.
RELEASE_NOTES="$(cd "$REPO_DIR" && bash ./scripts/release-notes.sh --limit 20)"

# The version name says which build a tester is on. It is the one passed in, such as a release tag without its v, or the package version followed by -dev and the build time. The version code is a whole number
# that only goes up, which Android needs to treat a new build as an update: minutes since the epoch always increases.
if [ -z "$APP_VERSION" ]; then
    APP_VERSION="$(jq -r '.version' "$APP_DIR/package.json")-dev.$(date -u +%Y%m%d%H%M%S)"
fi
VERSION_CODE=$(( $(date +%s) / 60 ))

# The phones testers have are arm64. The APK is the release build's, which is debug signed so that it installs.
echo "Building the Android APK ($APP_VERSION, version code $VERSION_CODE)..."
OUTPUT_DIR="$APP_DIR/out/android"
bash "$SCRIPT_DIR/package-android.sh" --arch arm64 --output-dir "$OUTPUT_DIR" --version-name "$APP_VERSION" --version-code "$VERSION_CODE"
APK_PATH="$OUTPUT_DIR/photosphere-$APP_VERSION-android-arm64.apk"
if [ ! -f "$APK_PATH" ]; then
    echo "ERROR: the build reported success but produced no APK at $APK_PATH." >&2
    exit 1
fi

if [ "$BUILD_ONLY" = "true" ]; then
    echo "Built $APK_PATH. --build-only was given, so nothing was uploaded."
    exit 0
fi

# The app's id in Firebase is found by its package name. When the project has no app for this package, one is created, so
# nothing has to be set up in the console first.
find_app_id() {
    firebase apps:list --project "$FIREBASE_PROJECT" --json \
        | jq -r --arg package "$APP_PACKAGE_NAME" '.result[] | select(.platform == "ANDROID" and .namespace == $package) | .appId' \
        | head -n 1
}

FIREBASE_APP_ID="$(find_app_id)"
if [ -z "$FIREBASE_APP_ID" ]; then
    echo "The Firebase project $FIREBASE_PROJECT has no Android app for $APP_PACKAGE_NAME. Creating it..."
    firebase apps:create ANDROID "$APP_DISPLAY_NAME" --package-name "$APP_PACKAGE_NAME" --project "$FIREBASE_PROJECT"
    FIREBASE_APP_ID="$(find_app_id)"
    if [ -z "$FIREBASE_APP_ID" ]; then
        echo "ERROR: the Firebase app for $APP_PACKAGE_NAME was created but cannot be found in the project." >&2
        exit 1
    fi
fi

echo "Uploading to Firebase App Distribution ($FIREBASE_APP_ID) for group(s) '$TESTER_GROUPS'..."
firebase appdistribution:distribute "$APK_PATH" \
    --project "$FIREBASE_PROJECT" \
    --app "$FIREBASE_APP_ID" \
    --groups "$TESTER_GROUPS" \
    --release-notes "$RELEASE_NOTES"

echo "Done. Testers in '$TESTER_GROUPS' have been notified."
