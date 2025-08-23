#!/bin/bash

set -e  # Exit immediately if any command fails

# Blacklist of directories to ignore
BLACKLIST=("node_modules" "deprecated")

# Build the find command with exclusions
EXCLUDE_ARGS="-not -path ./package.json"  # Always exclude root
for dir in "${BLACKLIST[@]}"; do
    EXCLUDE_ARGS="$EXCLUDE_ARGS -not -path */$dir/*"
done

# Find all directories containing package.json and run bun run test
find . -name "package.json" -type f $EXCLUDE_ARGS | while read -r package; do
    dir=$(dirname "$package")
    echo "Running tests in: $dir"
    cd "$dir" || exit 1
    bun run test
    cd - > /dev/null
done