#!/usr/bin/env bash
# Finds an unexpired workflow artifact, uploaded by a run on any branch, that holds a build of one third-party library under one key.
# The build-* actions use it instead of the Actions cache, which a run can only restore from its own branch or the default branch.
#
# Usage: find-library-artifact.sh <name-prefix> <key>
#   <name-prefix>  The start of the artifact's name, such as aws-sdk-linux-x64.
#   <key>          Everything the build depends on, as the action works it out.
#
# Writes name (the artifact's name) and run-id (the run that uploaded it, empty when there is none) to $GITHUB_OUTPUT.
# Needs GH_TOKEN with actions: read.
set -euo pipefail

# The runner image goes into the key, because a library built for the native target takes the libc of the image that built it. A
# Linux x64 AWS SDK built on ubuntu-26.04 (glibc 2.43) was reused on ubuntu-24.04 (glibc 2.39), where linking psi in
# zig-unit-tests-linux, zig-unit-tests and app-smoke-tests failed with "ld.lld: undefined symbol: __inet_pton_chk", a function
# glibc only has from 2.42. ImageOS (such as ubuntu24, macos15 or win25) is set on every GitHub-hosted runner and names the image's
# operating system release, not its weekly version, so a library is built again only when the release changes.
key="$2-${ImageOS:?ImageOS is not set, so the runner image cannot go into the library key}"

# An artifact's name may not hold a slash or a colon, which the build arguments in the key do, so the name carries a hash of the key.
# macOS has shasum rather than sha256sum.
if command -v sha256sum > /dev/null; then
    key_hash="$(printf '%s' "$key" | sha256sum | cut -d ' ' -f 1)"
else
    key_hash="$(printf '%s' "$key" | shasum -a 256 | cut -d ' ' -f 1)"
fi
name="$1-$key_hash"

# Every artifact of one name holds the same build, so any unexpired one will do. An error from the API fails the step.
run_id="$(gh api "repos/$GITHUB_REPOSITORY/actions/artifacts?name=$name&per_page=100" \
    --jq '[.artifacts[] | select(.expired == false)][0].workflow_run.id // ""')"

echo "Artifact $name: ${run_id:-none}"
echo "name=$name" >> "$GITHUB_OUTPUT"
echo "run-id=$run_id" >> "$GITHUB_OUTPUT"
