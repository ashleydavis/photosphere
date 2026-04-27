#!/bin/bash
DESCRIPTION="Import directory with duplicate content (dedupe to 1 asset)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/functions.sh"
trap cleanup_and_show_summary EXIT

test_add_duplicate_images 9
