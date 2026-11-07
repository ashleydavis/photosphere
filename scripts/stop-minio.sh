#!/usr/bin/env bash
# Stops the MinIO server start-minio.sh started for a manual test. See stop-minio.md.
#
# Usage:
#   bun run stop-minio -- <name>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ $# -ne 1 ]; then
    echo "Usage: bun run stop-minio -- <name>" >&2
    exit 2
fi
bash "$REPO_ROOT/scripts/s3-emulator.sh" stop "$REPO_ROOT/tmp/minio/$1/s3"
