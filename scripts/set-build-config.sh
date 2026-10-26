#!/usr/bin/env bash
# Writes packages/config/src/index.ts, the file the app reads its version and build metadata from, and
# stamps the same values into the two Zig config files (packages-zig/config-zig/src/index.zig and
# apps/cli-zig/src/lib/config.zig), and the version into app.zon.
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

# The Zig config files carry the same values, for the Zig builds.
ZIG_CONFIG_FILES=(
    "$REPO_DIR/packages-zig/config-zig/src/index.zig"
    "$REPO_DIR/apps/cli-zig/src/lib/config.zig"
)

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

# The values are written into Zig string literals with sed, so anything that could end the literal or
# be read by sed as syntax is refused rather than escaped.
if ! [[ "$VERSION" =~ ^[A-Za-z0-9._+-]+$ ]] || ! [[ "$COMMIT_HASH" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: version '$VERSION' or commit '$COMMIT_HASH' has characters outside letters, digits and . _ + -." >&2
    exit 1
fi

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

# Stamps a Zig config file in place: only the lines that carry the values are rewritten, so the rest of
# the file (its comments and the metadata struct) stays as checked in. The file is rewritten through a
# temporary file because `sed -i` takes different arguments on Linux and macOS. It fails when a line it
# should have stamped is not there afterwards, so a Zig config laid out differently is never left at "dev".
stamp_zig_config() {
    local zig_file="$1"
    local scratch_file="$zig_file.stamp"
    sed \
        -e 's|^pub const version = ".*";$|pub const version = "'"$VERSION"'";|' \
        -e 's|^    \.commitHash = ".*",$|    .commitHash = "'"$COMMIT_HASH"'",|' \
        -e 's|^    \.buildDate = ".*",$|    .buildDate = "'"$BUILD_DATE"'",|' \
        -e 's|^    \.isNightly = .*,$|    .isNightly = '"$IS_NIGHTLY"',|' \
        "$zig_file" > "$scratch_file"
    mv "$scratch_file" "$zig_file"
    local expected_line
    for expected_line in \
        'pub const version = "'"$VERSION"'";' \
        '    .commitHash = "'"$COMMIT_HASH"'",' \
        '    .buildDate = "'"$BUILD_DATE"'",' \
        '    .isNightly = '"$IS_NIGHTLY"','; do
        if ! grep -qxF -- "$expected_line" "$zig_file"; then
            echo "ERROR: $zig_file has no line '$expected_line' after stamping." >&2
            exit 1
        fi
    done
}

for ZIG_CONFIG_FILE in "${ZIG_CONFIG_FILES[@]}"; do
    stamp_zig_config "$ZIG_CONFIG_FILE"
done

# The version of app.zon, which Ziggy writes in the app's log files. Only its version line is rewritten, through a temporary file as
# above, and the script fails when it is not there afterwards.
APP_ZON_FILE="$REPO_DIR/app.zon"
sed -e 's|^    \.version = ".*",$|    .version = "'"$VERSION"'",|' "$APP_ZON_FILE" > "$APP_ZON_FILE.stamp"
mv "$APP_ZON_FILE.stamp" "$APP_ZON_FILE"
if ! grep -qxF -- '    .version = "'"$VERSION"'",' "$APP_ZON_FILE"; then
    echo "ERROR: $APP_ZON_FILE has no .version line for $VERSION after stamping." >&2
    exit 1
fi

echo "Build config set to version $VERSION, commit $COMMIT_HASH, nightly $IS_NIGHTLY." >&2

echo "$VERSION"
