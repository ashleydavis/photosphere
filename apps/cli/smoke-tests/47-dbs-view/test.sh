#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_dbs_view() {
    local test_number="$1"
    print_test_header "$test_number" "DBS VIEW"

    seed_databases_config '[{"name":"view-db","description":"A test database","path":"/tmp/view-db","encryptionKey":"enc00001","s3Key":"s3test01"}]'

    local dbs_output
    invoke_command "View database entry" "$(get_cli_command) dbs view --name view-db" 0 "dbs_output"

    expect_output_string "$dbs_output" "view-db" "Name appears in view output"
    expect_output_string "$dbs_output" "/tmp/view-db" "Path appears in view output"
    expect_output_string "$dbs_output" "enc00001" "Encryption key ID appears in view output"
    expect_output_string "$dbs_output" "s3test01" "S3 credential ID appears in view output"

    test_passed
}


test_dbs_view "${1:-47}"
