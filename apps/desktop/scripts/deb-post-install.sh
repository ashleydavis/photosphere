#!/bin/bash

#
# deb-post-install.sh
#
# Purpose:
#   Post-installation script for Photosphere .deb package.
#   Automatically fixes chrome-sandbox permissions after package installation.
#
# What it does:
#   1. Searches for chrome-sandbox in standard Electron installation directories
#   2. Sets ownership to root:root (required for SUID bit to work)
#   3. Sets permissions to 4755 (SUID bit enabled)
#
# When it runs:
#   - Automatically executed by dpkg/apt during .deb package installation
#   - Runs with root privileges (no user interaction required)
#   - Configured in package.json under build.linux.deb.afterInstall
#
# Why it's needed:
#   Electron's chrome-sandbox requires SUID permissions to enable sandboxing.
#   The SUID bit only works if the file is owned by root. This script ensures
#   the permissions are correctly set during installation so users don't need
#   to manually fix them.
#
# Output:
#   The script outputs status messages indicating:
#   - Where chrome-sandbox was found
#   - What permissions were changed
#   - Success or warning messages
#

set -e

echo "Photosphere post-install script: Fixing chrome-sandbox permissions..."
echo ""

# Electron-builder typically installs apps to /opt/<productName>
# For "Photosphere", this would be /opt/Photosphere
# We'll check common locations and also search for the file

CHROME_SANDBOX="chrome-sandbox"

# Try common installation locations
INSTALL_DIRS=(
    "/opt/Photosphere"
    "/opt/photosphere"
    "/usr/lib/Photosphere"
    "/usr/lib/photosphere"
    "/usr/share/Photosphere"
    "/usr/share/photosphere"
)

FOUND=0

echo "Searching for chrome-sandbox in standard installation directories..."
for INSTALL_DIR in "${INSTALL_DIRS[@]}"; do
    SANDBOX_PATH="${INSTALL_DIR}/${CHROME_SANDBOX}"
    if [ -f "${SANDBOX_PATH}" ]; then
        echo "✓ Found chrome-sandbox at: ${SANDBOX_PATH}"
        echo "  Current permissions: $(ls -l "${SANDBOX_PATH}" | awk '{print $1, $3, $4}')"
        echo "  Setting ownership to root:root..."
        chown root:root "${SANDBOX_PATH}"
        echo "  Setting permissions to 4755 (SUID)..."
        chmod 4755 "${SANDBOX_PATH}"
        echo "  New permissions: $(ls -l "${SANDBOX_PATH}" | awk '{print $1, $3, $4}')"
        echo "✓ Successfully fixed chrome-sandbox permissions"
        FOUND=1
        break
    fi
done

# If not found, search for it (this handles any installation path)
if [ $FOUND -eq 0 ]; then
    echo "Not found in standard locations. Searching in /opt and /usr..."
    # Search in /opt and /usr for chrome-sandbox files
    # Limit to first result to avoid modifying multiple files
    SANDBOX_PATH=$(find /opt /usr -name "${CHROME_SANDBOX}" -type f 2>/dev/null | head -1)
    if [ -n "${SANDBOX_PATH}" ] && [ -f "${SANDBOX_PATH}" ]; then
        # Verify it's likely our app's sandbox (check if parent dir contains our executable)
        PARENT_DIR=$(dirname "${SANDBOX_PATH}")
        if [ -f "${PARENT_DIR}/photosphere" ] || [ -f "${PARENT_DIR}/Photosphere" ]; then
            echo "✓ Found chrome-sandbox at: ${SANDBOX_PATH}"
            echo "  Current permissions: $(ls -l "${SANDBOX_PATH}" | awk '{print $1, $3, $4}')"
            echo "  Setting ownership to root:root..."
            chown root:root "${SANDBOX_PATH}"
            echo "  Setting permissions to 4755 (SUID)..."
            chmod 4755 "${SANDBOX_PATH}"
            echo "  New permissions: $(ls -l "${SANDBOX_PATH}" | awk '{print $1, $3, $4}')"
            echo "✓ Successfully fixed chrome-sandbox permissions"
            FOUND=1
        fi
    fi
fi

if [ $FOUND -eq 0 ]; then
    echo "⚠ Warning: chrome-sandbox not found in expected locations."
    echo "  This may be normal if the app uses a non-standard installation path."
    echo "  If the app fails to start, manually run:"
    echo "    sudo chown root:root <path-to-chrome-sandbox>"
    echo "    sudo chmod 4755 <path-to-chrome-sandbox>"
fi

echo ""
echo "Post-install script completed."
