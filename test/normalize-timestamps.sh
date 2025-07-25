#!/bin/bash

# Normalize file timestamps for test assets to ensure deterministic smoke tests
# This script sets all test files to a fixed timestamp: 2024-01-01 00:00:00 UTC

# Define the fixed timestamp (January 1, 2024, 00:00:00 UTC)
# Use Unix timestamp to ensure timezone consistency
FIXED_UNIX_TIMESTAMP="1704067200"  # 2024-01-01 00:00:00 UTC

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Normalizing file timestamps for test assets..."
echo "Script directory: $SCRIPT_DIR"

# Function to set timestamp for a file
set_timestamp() {
    local file="$1"
    if [ -f "$file" ]; then
        # Get timestamp before change
        local before_mtime=$(stat -c "%Y" "$file" 2>/dev/null)
        local before_readable=$(stat -c "%y" "$file" 2>/dev/null)
        
        # Change the timestamp using Unix timestamp to ensure UTC consistency
        touch -d "@$FIXED_UNIX_TIMESTAMP" "$file"
        
        # Get timestamp after change
        local after_mtime=$(stat -c "%Y" "$file" 2>/dev/null)
        local after_readable=$(stat -c "%y" "$file" 2>/dev/null)
        
        echo "  ✓ $file"
        echo "    Before: mtime=$before_mtime ($before_readable)"
        echo "    After:  mtime=$after_mtime ($after_readable)"
    else
        echo "  ✗ File not found: $file"
    fi
}

# Set timestamp for direct test files
set_timestamp "$SCRIPT_DIR/test.jpg"
set_timestamp "$SCRIPT_DIR/test.png"
set_timestamp "$SCRIPT_DIR/test.mp4"
set_timestamp "$SCRIPT_DIR/test.webp"

# Set timestamp for multiple-images directory files
echo ""
echo "Normalizing multiple-images directory files:"
for file in "$SCRIPT_DIR/multiple-images"/*; do
    if [ -f "$file" ]; then
        set_timestamp "$file"
    fi
done

echo ""
echo "File timestamp normalization complete."
echo "All test assets now have timestamp: 2024-01-01 00:00:00 UTC"
echo "Expected mtime value: $FIXED_UNIX_TIMESTAMP"

# Verify a few key files
echo ""
echo "Verification of key test files:"
for verify_file in "$SCRIPT_DIR/test.jpg" "$SCRIPT_DIR/test.png" "$SCRIPT_DIR/test.mp4"; do
    if [ -f "$verify_file" ]; then
        final_mtime=$(stat -c "%Y" "$verify_file" 2>/dev/null)
        final_readable=$(stat -c "%y" "$verify_file" 2>/dev/null)
        if [ "$final_mtime" = "$FIXED_UNIX_TIMESTAMP" ]; then
            echo "  ✓ $verify_file: mtime=$final_mtime ($final_readable) - CORRECT"
        else
            echo "  ✗ $verify_file: mtime=$final_mtime ($final_readable) - INCORRECT!"
        fi
    fi
done