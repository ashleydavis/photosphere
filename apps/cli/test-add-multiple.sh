#!/bin/bash

# Quick test script to create a database and add multiple files (test 7 assets)
# This is useful for quickly testing the add functionality without running full smoke tests

set -e

TEST_DB_DIR="./test/tmp/test-add-multiple"
MULTIPLE_IMAGES_DIR="../../test/multiple-images"

# Delete test database if it exists
echo "Deleting test database if it exists..."
rm -rf "$TEST_DB_DIR"

# Create new database
echo "Creating new database at: $TEST_DB_DIR"
bun run start -- init --db "$TEST_DB_DIR" --yes

echo ""
echo "Adding files from: $MULTIPLE_IMAGES_DIR"
bun run start -- add --db "$TEST_DB_DIR" "$MULTIPLE_IMAGES_DIR/" --yes --verbose