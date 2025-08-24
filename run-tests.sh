#!/bin/bash

set -e

# Directories to ignore
BLACKLIST="node_modules deprecated packages/rest-api"

# Find and test all packages
find . -name "package.json" -not -path "./package.json" | grep -vE "($(echo $BLACKLIST | tr ' ' '|'))" | while read package; do
    dir=$(dirname "$package")
    
    # Check if package.json has a test script
    if grep -q '"test":' "$package"; then
        echo "Testing: $dir"
        if ! (cd "$dir" && bun run test); then
            echo "❌ TESTS FAILED IN: $dir"
            exit 1
        fi
    else
        echo "Skipping $dir (no test script found)"
    fi
done