#!/usr/bin/env bash

# Removes the example's build output on every platform this machine can build for. See clean.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for platform in linux windows android; do
    bash "$SCRIPT_DIR/clean-$platform.sh"
done

if [ "$(uname -s)" = "Darwin" ]; then
    for platform in macos ios; do
        bash "$SCRIPT_DIR/clean-$platform.sh"
    done
fi
