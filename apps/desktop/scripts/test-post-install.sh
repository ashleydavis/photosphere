#!/bin/bash

#
# test-post-install.sh
#
# Purpose:
#   Test script to verify chrome-sandbox permission fixes on unpacked builds.
#   Allows testing the same permission changes that deb-post-install.sh performs
#   during .deb package installation.
#
# What it does:
#   1. Locates chrome-sandbox in the linux-unpacked build directory
#   2. Shows current permissions and ownership
#   3. Applies the same fixes as the post-install script:
#      - Sets ownership to root:root (requires sudo)
#      - Sets permissions to 4755 (SUID bit)
#   4. Verifies the changes were successful
#
# How to use:
#   Option 1: Use the npm script (recommended)
#     cd apps/desktop
#     bun run test:post-install
#
#   Option 2: Run directly
#     cd apps/desktop
#     bash scripts/test-post-install.sh
#
#   Option 3: Test a specific directory
#     bash scripts/test-post-install.sh /path/to/custom/linux-unpacked
#
# Requirements:
#   - Must have built the Linux app first (linux-unpacked directory must exist)
#   - Requires sudo access (will prompt for password)
#
# Output:
#   The script provides detailed output showing:
#   - Current permissions before changes
#   - Each step being performed
#   - New permissions after changes
#   - Verification of success or failure
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNPACKED_DIR="${1:-${SCRIPT_DIR}/../release/linux-unpacked}"

if [ ! -d "${UNPACKED_DIR}" ]; then
    echo "Error: Unpacked directory not found: ${UNPACKED_DIR}"
    echo "Usage: $0 [path-to-linux-unpacked]"
    echo "Default: ${SCRIPT_DIR}/../release/linux-unpacked"
    exit 1
fi

CHROME_SANDBOX="${UNPACKED_DIR}/chrome-sandbox"

if [ ! -f "${CHROME_SANDBOX}" ]; then
    echo "Error: chrome-sandbox not found at: ${CHROME_SANDBOX}"
    echo "Make sure you have built the Linux app first."
    exit 1
fi

echo "=========================================="
echo "Testing chrome-sandbox permission fix"
echo "=========================================="
echo ""
echo "Target directory: ${UNPACKED_DIR}"
echo "chrome-sandbox path: ${CHROME_SANDBOX}"
echo ""

# Show current permissions
echo "--- Current state ---"
echo "Permissions: $(ls -l "${CHROME_SANDBOX}" | awk '{print $1}')"
echo "Owner: $(stat -c '%U:%G' "${CHROME_SANDBOX}")"
echo "Full details:"
ls -l "${CHROME_SANDBOX}"
echo ""

# Test the fix (requires sudo)
echo "--- Applying fix (requires sudo) ---"
echo "1. Setting ownership to root:root..."
sudo chown root:root "${CHROME_SANDBOX}"
echo "   ✓ Ownership changed"

echo "2. Setting permissions to 4755 (SUID bit)..."
sudo chmod 4755 "${CHROME_SANDBOX}"
echo "   ✓ Permissions changed"
echo ""

# Show new permissions
echo "--- New state ---"
echo "Permissions: $(ls -l "${CHROME_SANDBOX}" | awk '{print $1}')"
echo "Owner: $(stat -c '%U:%G' "${CHROME_SANDBOX}")"
echo "Full details:"
ls -l "${CHROME_SANDBOX}"
echo ""

# Verify the fix
echo "--- Verification ---"
ACTUAL_OWNER=$(stat -c '%U:%G' "${CHROME_SANDBOX}")
ACTUAL_PERMS=$(stat -c '%a' "${CHROME_SANDBOX}")

if [ "${ACTUAL_OWNER}" = "root:root" ] && [ "${ACTUAL_PERMS}" = "4755" ]; then
    echo "✓ SUCCESS! chrome-sandbox permissions are correctly set."
    echo "  Owner: ${ACTUAL_OWNER} (expected: root:root)"
    echo "  Permissions: ${ACTUAL_PERMS} (expected: 4755)"
    echo "  SUID bit is set, sandbox should work correctly."
else
    echo "✗ WARNING: Permissions may not be correct."
    echo "  Owner: ${ACTUAL_OWNER} (expected: root:root)"
    echo "  Permissions: ${ACTUAL_PERMS} (expected: 4755)"
    if [ "${ACTUAL_OWNER}" != "root:root" ]; then
        echo "  ⚠ Owner is not root:root - SUID bit will not work!"
    fi
    if [ "${ACTUAL_PERMS}" != "4755" ]; then
        echo "  ⚠ Permissions are not 4755 - SUID bit may not be set!"
    fi
fi
echo ""
echo "=========================================="
