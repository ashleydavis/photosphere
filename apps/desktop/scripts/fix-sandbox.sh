#!/bin/bash

#
# fix-sandbox.sh
#
# Purpose:
#   Simple script to fix chrome-sandbox permissions for Photosphere.
#   Designed for users who installed from the ZIP file.
#
# What it does:
#   Sets ownership to root:root and permissions to 4755 (SUID) on chrome-sandbox
#   in the current directory.
#
# How to use:
#   1. Extract the Photosphere ZIP file
#   2. Navigate to the extracted directory
#   3. Run: bash scripts/fix-sandbox.sh
#   4. Enter your password when prompted
#
# Requirements:
#   - Must be run from the directory containing chrome-sandbox
#   - Requires sudo access (will prompt for password)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHROME_SANDBOX="${APP_DIR}/chrome-sandbox"

if [ ! -f "${CHROME_SANDBOX}" ]; then
    echo "Error: chrome-sandbox not found at: ${CHROME_SANDBOX}"
    echo "Make sure you're running this script from the Photosphere directory."
    exit 1
fi

echo "Fixing chrome-sandbox permissions..."
echo "Location: ${CHROME_SANDBOX}"
echo ""

echo "Current permissions:"
ls -l "${CHROME_SANDBOX}"
echo ""

echo "Setting ownership to root:root (requires sudo)..."
sudo chown root:root "${CHROME_SANDBOX}"

echo "Setting permissions to 4755 (SUID bit)..."
sudo chmod 4755 "${CHROME_SANDBOX}"

echo ""
echo "New permissions:"
ls -l "${CHROME_SANDBOX}"
echo ""

# Verify
ACTUAL_OWNER=$(stat -c '%U:%G' "${CHROME_SANDBOX}")
ACTUAL_PERMS=$(stat -c '%a' "${CHROME_SANDBOX}")

if [ "${ACTUAL_OWNER}" = "root:root" ] && [ "${ACTUAL_PERMS}" = "4755" ]; then
    echo "✓ Success! chrome-sandbox permissions are correctly set."
    echo "  You can now run ./photosphere"
else
    echo "✗ Warning: Permissions may not be correct."
    echo "  Owner: ${ACTUAL_OWNER} (expected: root:root)"
    echo "  Permissions: ${ACTUAL_PERMS} (expected: 4755)"
    exit 1
fi
