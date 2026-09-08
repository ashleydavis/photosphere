#!/usr/bin/env bash
# Builds the Android app and uploads it to Firebase App Distribution, which notifies the tester group
# and gives them a link to install it.
#
# The build is the debug APK, the same one `bun run and` puts on the emulator, because the app has no
# release signing set up: an unsigned release APK installs nowhere. See
# docs/android-tester-distribution.md for what that costs the tester.
#
# The release notes testers read come from scripts/release-notes.sh, the same script the GitHub
# release workflow generates its notes with, so a tester build and a release describe the same
# commits the same way. The version comes from scripts/set-build-config.sh, which versions this the
# way the workflow versions a nightly.
#
# Usage: bun run dist:and [options]
#   --groups a,b     Tester group aliases to release to (default: testers)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$APP_ROOT/../.." && pwd)"

# The Firebase app id of the Photosphere Android app, from the Firebase console under Project
# settings > General > Your apps. It identifies which app a build belongs to and is not a secret.
# Recreating the Firebase project, or adding the Android app to a different one, changes it.
FIREBASE_APP_ID="1:1057350534026:android:ddbee53ffce2c34fdefe73"

# What the Gradle debug build produces, and what gets uploaded.
APK_PATH="$APP_ROOT/android/app/build/outputs/apk/debug/app-debug.apk"

TESTER_GROUPS="testers"

while [ $# -gt 0 ]; do
    case "$1" in
        --groups)
            TESTER_GROUPS="$2"
            shift 2
            ;;
        *)
            echo "ERROR: unknown argument '$1'. Options: --groups." >&2
            exit 1
            ;;
    esac
done

# Checked before the build rather than after it, so a missing CLI costs a second instead of a full
# Gradle run.
if ! command -v firebase >/dev/null 2>&1; then
    echo "ERROR: the Firebase CLI is not on your PATH." >&2
    echo "Install it with 'curl -sL https://firebase.tools | bash', then run 'firebase login'." >&2
    exit 1
fi

# Limited because Firebase App Distribution rejects long release notes: an upload with every commit
# since the last tag came back "Release notes length exceeds maximum character limit", which fails
# the run after the whole APK has gone up. Twenty is well inside that and is as much as a tester
# reads anyway.
RELEASE_NOTES="$(cd "$REPO_DIR" && bash ./scripts/release-notes.sh --limit 20)"

# The version the app reports lives in a tracked file that a local build leaves saying "dev", so it
# is rewritten for the build and put back afterwards, however the build ends. The backup name is
# unique so a second distribute running beside this one cannot restore the wrong contents.
BUILD_CONFIG="$REPO_DIR/packages/config/src/index.ts"
mkdir -p "$REPO_DIR/tmp"
BUILD_CONFIG_BACKUP="$(mktemp "$REPO_DIR/tmp/build-config-backup.XXXXXX")"
cp "$BUILD_CONFIG" "$BUILD_CONFIG_BACKUP"

# Restores what was there before, including on a failed build, so an interrupted distribute never
# leaves a stamped version behind for every later local build to report.
restore_build_config() {
    cp "$BUILD_CONFIG_BACKUP" "$BUILD_CONFIG"
    rm -f "$BUILD_CONFIG_BACKUP"
}
trap restore_build_config EXIT

# Versioned as the release workflow versions a nightly: dev-nightly.<UTC timestamp>, stamped with the
# commit being built. Without this the app reports "dev" to a tester, which says nothing about which
# build they are on.
APP_VERSION="$(cd "$REPO_DIR" && bash ./scripts/set-build-config.sh)"

# Android wants a whole number that only ever goes up, which the version name above is not. Minutes
# since the epoch gives one: it always increases, and it stays far below Android's ceiling.
VERSION_CODE=$(( $(date +%s) / 60 ))

echo "Building the web assets and the worker bundle..."
cd "$APP_ROOT"
bun run sync

# Through android-gradle.sh rather than gradlew directly, so JAVA_HOME (a JDK 17) and the Android SDK
# are resolved here the way they are for every other Android command, instead of the caller having to
# export them.
echo "Building the debug APK ($APP_VERSION, version code $VERSION_CODE)..."
"$SCRIPT_DIR/android-gradle.sh" :app:assembleDebug \
    "-PphotosphereVersionName=$APP_VERSION" \
    "-PphotosphereVersionCode=$VERSION_CODE"

if [ ! -f "$APK_PATH" ]; then
    echo "ERROR: the build reported success but produced no APK at $APK_PATH." >&2
    exit 1
fi

echo "Uploading to Firebase App Distribution for group(s) '$TESTER_GROUPS'..."
firebase appdistribution:distribute "$APK_PATH" \
    --app "$FIREBASE_APP_ID" \
    --groups "$TESTER_GROUPS" \
    --release-notes "$RELEASE_NOTES"

echo "Done. Testers in '$TESTER_GROUPS' have been notified."
