#!/bin/bash

# Test summary and verify commands on all generated databases

set -e

CLI_DIR="apps/cli"
DBS_DIR="test/dbs"

databases=(
    "1-asset"
    "50-assets"
    "multi-set/93886ac9-16e4-48e6-983b-ec65566018d0"
    "multi-set/93886ac9-16e4-48e6-983b-ec65566018d1"
    "no-assets"
)

errors=0

echo "Testing CLI commands on generated databases..."
echo ""

for db in "${databases[@]}"; do
    db_path="$DBS_DIR/$db"
    
    if [ ! -d "$db_path" ]; then
        echo "✗ Database not found: $db_path"
        errors=$((errors + 1))
        continue
    fi
    
    echo "Testing database: $db"
    echo "  Path: $db_path"
    
    # Test summary command
    echo "  Running summary..."
    if (cd "$CLI_DIR" && bun run start -- summary --db "../../$db_path" --yes) > /tmp/summary_${db//\//_}.log 2>&1; then
        echo "    ✓ summary succeeded"
    else
        echo "    ✗ summary failed (exit code: $?)"
        echo "    Output:"
        cat /tmp/summary_${db//\//_}.log | sed 's/^/      /'
        errors=$((errors + 1))
    fi
    
    # Test verify command
    echo "  Running verify..."
    if (cd "$CLI_DIR" && bun run start -- verify --db "../../$db_path" --yes) > /tmp/verify_${db//\//_}.log 2>&1; then
        echo "    ✓ verify succeeded"
    else
        echo "    ✗ verify failed (exit code: $?)"
        echo "    Output:"
        cat /tmp/verify_${db//\//_}.log | sed 's/^/      /'
        errors=$((errors + 1))
    fi
    
    echo ""
done

if [ $errors -eq 0 ]; then
    echo "✓ All CLI commands passed successfully!"
    exit 0
else
    echo "✗ $errors error(s) found"
    exit 1
fi

