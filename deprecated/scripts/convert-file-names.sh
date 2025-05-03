#!/bin/bash

# Script to add dashes to UUID filenames
# Converts xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx to xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# Check if directory argument is provided
if [ $# -ne 1 ]; then
    echo "Usage: $0 <directory_path>"
    exit 1
fi

DIRECTORY="$1"

# Check if the provided path is a directory
if [ ! -d "$DIRECTORY" ]; then
    echo "Error: '$DIRECTORY' is not a valid directory."
    exit 1
fi

# Navigate to the directory
cd "$DIRECTORY" || exit 1

pwd

# Count for reporting
COUNT=0

# Process each file in the directory
for file in *; do
    # Skip if it's not a file
    if [ ! -f "$file" ]; then
        continue
    fi
    
    echo "Considering file: $file"
    
    # Extract the filename and extension
    filename=$(basename -- "$file")
    extension=""
    
    # Check if file has an extension
    if [[ "$filename" == *.* ]]; then
        extension=".${filename##*.}"
        filename="${filename%.*}"
    fi
    
    # Check if filename is a UUID without dashes (32 hex chars)
    if [[ "$filename" =~ ^[a-fA-F0-9]{32}$ ]]; then
        # Format with dashes in UUID format
        new_filename="${filename:0:8}-${filename:8:4}-${filename:12:4}-${filename:16:4}-${filename:20:12}${extension}"
        
        # Rename the file
        mv "$file" "$new_filename"
        echo "  Renamed: $file -> $new_filename"
        ((COUNT++))
    else
        echo "  Skipped: Not a UUID format or already has dashes"
    fi
done

echo "Completed: $COUNT files renamed."