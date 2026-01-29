#!/bin/bash

#
# Compares two directories by file size only.
# Shows files that differ in size or are missing on either side.
# Uses parallel processing for performance.
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Show usage if no parameters provided
if [ $# -lt 2 ]; then
    echo "Usage: $0 <dir1> <dir2> [options]"
    echo ""
    echo "Compares two directories by file size only."
    echo "Shows files that differ in size or are missing on either side."
    echo ""
    echo "Options:"
    echo "  --jobs <n>    Number of parallel jobs (default: number of CPU cores)"
    echo "  --help         Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 /path/to/dir1 /path/to/dir2"
    echo "  $0 /path/to/dir1 /path/to/dir2 --jobs 8"
    exit 1
fi

# Parse arguments
DIR1=""
DIR2=""
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

while [[ $# -gt 0 ]]; do
    case $1 in
        --jobs)
            JOBS="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 <dir1> <dir2> [options]"
            echo ""
            echo "Compares two directories by file size only."
            echo "Shows files that differ in size or are missing on either side."
            echo ""
            echo "Options:"
            echo "  --jobs <n>    Number of parallel jobs (default: number of CPU cores)"
            echo "  --help         Show this help message"
            exit 0
            ;;
        *)
            if [ -z "$DIR1" ]; then
                DIR1="$1"
            elif [ -z "$DIR2" ]; then
                DIR2="$1"
            else
                echo "Error: Too many arguments" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate directories
if [ -z "$DIR1" ] || [ -z "$DIR2" ]; then
    echo "Error: Both directories must be specified" >&2
    exit 1
fi

if [ ! -d "$DIR1" ]; then
    echo "Error: Directory '$DIR1' does not exist" >&2
    exit 1
fi

if [ ! -d "$DIR2" ]; then
    echo "Error: Directory '$DIR2' does not exist" >&2
    exit 1
fi

# Make paths absolute
DIR1=$(cd "$DIR1" && pwd)
DIR2=$(cd "$DIR2" && pwd)

echo -e "${BLUE}Comparing directories:${NC}"
echo "  Dir1: $DIR1"
echo "  Dir2: $DIR2"
echo "  Jobs: $JOBS"
echo ""

# Function to get file size
get_size() {
    local file="$1"
    if [ -f "$file" ]; then
        stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Function to compare a single file
compare_file() {
    local rel_path="$1"
    local file1="$DIR1/$rel_path"
    local file2="$DIR2/$rel_path"
    
    local size1=0
    local size2=0
    local exists1=false
    local exists2=false
    
    if [ -f "$file1" ]; then
        exists1=true
        size1=$(get_size "$file1")
    fi
    
    if [ -f "$file2" ]; then
        exists2=true
        size2=$(get_size "$file2")
    fi
    
    if [ "$exists1" = false ] && [ "$exists2" = false ]; then
        return 0
    fi
    
    if [ "$exists1" = false ]; then
        echo "MISSING1|$rel_path|$size2"
        return 0
    fi
    
    if [ "$exists2" = false ]; then
        echo "MISSING2|$rel_path|$size1"
        return 0
    fi
    
    if [ "$size1" -ne "$size2" ]; then
        echo "DIFFER|$rel_path|$size1|$size2"
        return 0
    fi
    
    return 0
}

# Export function and variables for parallel processing
export -f get_size compare_file
export DIR1 DIR2

# Find all files in both directories and create a unique list
echo -e "${BLUE}Scanning directories...${NC}"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Get relative paths from both directories
find "$DIR1" -type f -print0 | while IFS= read -r -d '' file; do
    rel_path="${file#$DIR1/}"
    echo "$rel_path"
done > "$TMPDIR/files1.txt"

find "$DIR2" -type f -print0 | while IFS= read -r -d '' file; do
    rel_path="${file#$DIR2/}"
    echo "$rel_path"
done > "$TMPDIR/files2.txt"

ALL_FILES=$(sort -u "$TMPDIR/files1.txt" "$TMPDIR/files2.txt")

TOTAL_FILES=$(echo "$ALL_FILES" | wc -l)
echo "Found $TOTAL_FILES unique file paths"
echo ""

# Compare files in parallel
echo -e "${BLUE}Comparing files (using $JOBS parallel jobs)...${NC}"

echo "$ALL_FILES" | xargs -P "$JOBS" -I {} bash -c 'compare_file "{}"' > "$TMPDIR/results.txt"

# Process results
MISSING1_COUNT=0
MISSING2_COUNT=0
DIFFER_COUNT=0
MATCH_COUNT=0

MISSING1_FILE="$TMPDIR/missing1.txt"
MISSING2_FILE="$TMPDIR/missing2.txt"
DIFFER_FILE="$TMPDIR/differ.txt"

touch "$MISSING1_FILE" "$MISSING2_FILE" "$DIFFER_FILE"

while IFS='|' read -r status rest; do
    case "$status" in
        MISSING1)
            MISSING1_COUNT=$((MISSING1_COUNT + 1))
            echo "$rest" >> "$MISSING1_FILE"
            ;;
        MISSING2)
            MISSING2_COUNT=$((MISSING2_COUNT + 1))
            echo "$rest" >> "$MISSING2_FILE"
            ;;
        DIFFER)
            DIFFER_COUNT=$((DIFFER_COUNT + 1))
            echo "$rest" >> "$DIFFER_FILE"
            ;;
    esac
done < "$TMPDIR/results.txt"

MATCH_COUNT=$((TOTAL_FILES - MISSING1_COUNT - MISSING2_COUNT - DIFFER_COUNT))

# Display results
echo ""
echo -e "${BLUE}=== Results ===${NC}"
echo "Total files: $TOTAL_FILES"
echo -e "  ${GREEN}Match: $MATCH_COUNT${NC}"
echo -e "  ${YELLOW}Different size: $DIFFER_COUNT${NC}"
echo -e "  ${RED}Missing in dir1: $MISSING1_COUNT${NC}"
echo -e "  ${RED}Missing in dir2: $MISSING2_COUNT${NC}"
echo ""

# Show missing files in dir1
if [ $MISSING1_COUNT -gt 0 ]; then
    echo -e "${RED}Files missing in dir1 (present in dir2):${NC}"
    while IFS='|' read -r path size; do
        echo -e "  ${RED}-${NC} $path (size: $size bytes)"
    done < "$MISSING1_FILE"
    echo ""
fi

# Show missing files in dir2
if [ $MISSING2_COUNT -gt 0 ]; then
    echo -e "${RED}Files missing in dir2 (present in dir1):${NC}"
    while IFS='|' read -r path size; do
        echo -e "  ${RED}-${NC} $path (size: $size bytes)"
    done < "$MISSING2_FILE"
    echo ""
fi

# Show files with different sizes
if [ $DIFFER_COUNT -gt 0 ]; then
    echo -e "${YELLOW}Files with different sizes:${NC}"
    while IFS='|' read -r path size1 size2; do
        echo -e "  ${YELLOW}~${NC} $path"
        echo "    dir1: $size1 bytes"
        echo "    dir2: $size2 bytes"
    done < "$DIFFER_FILE"
    echo ""
fi

# Exit with appropriate code
if [ $MISSING1_COUNT -gt 0 ] || [ $MISSING2_COUNT -gt 0 ] || [ $DIFFER_COUNT -gt 0 ]; then
    exit 1
else
    exit 0
fi
