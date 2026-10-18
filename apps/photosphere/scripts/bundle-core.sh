#!/usr/bin/env bash

# Builds Photosphere's core as a library for one Zig target, from the root of the repository. See bundle-core.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

TARGET=""
OPTIMIZE="ReleaseSafe"
HOOKS_ARGUMENT="-Dtest-hooks=false"
PREFIX_ARGUMENTS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --test-hooks)
            HOOKS_ARGUMENT="-Dtest-hooks=true"
            shift
            ;;
        --optimize)
            OPTIMIZE="$2"
            shift 2
            ;;
        --prefix)
            PREFIX_ARGUMENTS=(--prefix "$2")
            shift 2
            ;;
        -*)
            echo "Unknown argument $1. See bundle-core.md." >&2
            exit 2
            ;;
        *)
            TARGET="$1"
            shift
            ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "bundle-core.sh needs a Zig target, for example x86_64-linux-gnu. See bundle-core.md." >&2
    exit 2
fi

(cd "$REPO_ROOT" && zig build photosphere-backend "-Dtarget=$TARGET" "-Doptimize=$OPTIMIZE" "$HOOKS_ARGUMENT" "${PREFIX_ARGUMENTS[@]+"${PREFIX_ARGUMENTS[@]}"}")
