#!/usr/bin/env bash
# Writes packages/config/src/index.ts, the file the app reads its version and build metadata from.
# The version is compiled into every frontend at build time, so this runs before a build, not after.
#
# The checked-in file says "dev", which is what a local build reports. A build meant for anyone else
# replaces it: a tagged release reports the tag, and anything else reports a nightly version stamped
# with the time it was built, which is how the release workflow's nightly builds are versioned and
# how the Android tester builds are versioned too.
#
# The version goes to stdout and nothing else does, so a caller can capture it and label a build with
# it. Whoever calls this is responsible for putting the checked-in file back afterwards.
#
# Usage: scripts/set-build-config.sh [options]
#   --tag <tag>      The release tag being built, with or without its leading "v". Without it, or
#                    with an empty one, the build is a nightly.
#   --commit <sha>   The commit being built (default: the current HEAD).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$REPO_DIR/packages/config/src/index.ts"

TAG=""
COMMIT_HASH=""

while [ $# -gt 0 ]; do
    case "$1" in
        --tag)
            TAG="$2"
            shift 2
            ;;
        --commit)
            COMMIT_HASH="$2"
            shift 2
            ;;
        *)
            echo "ERROR: unknown argument '$1'. Options: --tag, --commit." >&2
            exit 1
            ;;
    esac
done

if [ -z "$COMMIT_HASH" ]; then
    COMMIT_HASH="$(git -C "$REPO_DIR" rev-parse HEAD)"
fi

if [ -n "$TAG" ]; then
    VERSION="${TAG#v}"
    IS_NIGHTLY="false"
else
    VERSION="dev-nightly.$(date -u +'%Y%m%dT%H%M%S')"
    IS_NIGHTLY="true"
fi

BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

{
    echo '// Version is set by the CI build process. "dev" is used for local development.'
    echo 'export const version = "'"$VERSION"'";'
    echo ""
    echo "// Build metadata is set by the CI build process."
    echo "export const buildMetadata = {"
    echo '    commitHash: "'"$COMMIT_HASH"'",'
    echo '    buildDate: "'"$BUILD_DATE"'",'
    echo "    isNightly: $IS_NIGHTLY,"
    echo "};"
} > "$CONFIG_FILE"

echo "Build config set to version $VERSION, commit $COMMIT_HASH, nightly $IS_NIGHTLY." >&2

echo "$VERSION"
