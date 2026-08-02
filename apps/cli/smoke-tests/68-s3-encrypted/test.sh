#!/bin/bash
DESCRIPTION="Encrypted database stored on S3"

# Covers EncryptedStorage wrapped around CloudStorage, which nothing else does: the encrypted CLI
# suite (apps/cli/smoke-tests-encrypted.sh) is filesystem-only, so the encryption layer has never run
# over an s3: path.
#
# The assertion that matters is the ciphertext check. `list` and `verify` reading the database back
# would pass equally well if the bytes in the bucket were plaintext, because the same process wrote
# them; fetching the stored object straight out of the bucket with the S3 API and confirming it is NOT
# the source file's bytes is what proves the encryption layer is actually in the path over S3.
#
# The final assertion is the other half: with the key gone from the vault, a read must fail loudly
# rather than return nothing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TEST_NUMBER="${1:-68}"

# Per-process scratch directory: a single-test run does not clear the tree the way a full suite run
# does, so a fixed name would collide with the last run's output.
TEST_DIR="$(get_test_dir "$TEST_NUMBER")/run-$$"
S3_STATE_DIR="$TEST_DIR/s3"
KEY_NAME="s3enc68"

cleanup_s3_and_show_summary() {
    local exit_code=$?
    stop_s3_emulator "$S3_STATE_DIR"
    return $exit_code
}
trap 'cleanup_s3_and_show_summary; cleanup_and_show_summary' EXIT

#
# Runs a scripts/s3-object.ts subcommand against the emulator's bucket, passing the connection
# settings the emulator reported. Usage: s3_object <subcommand> [args...]
#
s3_object() {
    local subcommand="$1"
    shift
    bun "$REPO_ROOT/scripts/s3-object.ts" "$subcommand" \
        --endpoint "$S3_ENDPOINT" \
        --bucket "$S3_EMULATOR_BUCKET" \
        --access-key "$S3_EMULATOR_ACCESS_KEY" \
        --secret-key "$S3_EMULATOR_SECRET_KEY" \
        "$@"
}

test_s3_encrypted() {
    local test_number="$1"
    print_test_header "$test_number" "S3 ENCRYPTED DATABASE"

    start_s3_emulator "$S3_STATE_DIR"
    export_s3_env_credentials

    mkdir -p "$TEST_DIR"

    local s3_db="s3:$S3_EMULATOR_BUCKET/encrypted"
    log_info "Database path: $s3_db"

    invoke_command "Initialize an encrypted database on S3" \
        "$(get_cli_command) init --db \"$s3_db\" --key $KEY_NAME --generate-key --yes" 0

    invoke_command "Add a JPG to the encrypted S3 database" \
        "$(get_cli_command) add $TEST_FILES_DIR/test.jpg --db \"$s3_db\" --key $KEY_NAME --yes" 0

    # --- The bytes in the bucket must not be the source file's bytes. ---

    # Exactly one asset has been added so far, so the single object under the asset prefix is
    # unambiguously the encrypted form of test.jpg.
    local asset_count
    asset_count="$(s3_object count --prefix "encrypted/asset")"
    expect_value "$asset_count" "1" "One asset object is stored in the bucket"

    local asset_key
    asset_key="$(s3_object list --prefix "encrypted/asset" | head -1)"
    log_info "Stored asset object: $asset_key"

    local stored_object="$TEST_DIR/stored-asset.bin"
    s3_object get --key "$asset_key" > "$stored_object"

    if cmp -s "$stored_object" "$TEST_FILES_DIR/test.jpg"; then
        log_error "The object stored in the bucket is byte-identical to the source file: the encryption layer is not in the S3 path"
        exit 1
    fi
    log_success "The object stored in the bucket is not the source file's plaintext"

    # --- The database still reads back correctly through the encryption layer. ---

    invoke_command "Add an MP4 to the encrypted S3 database" \
        "$(get_cli_command) add $TEST_FILES_DIR/multiple-files/test.mp4 --db \"$s3_db\" --key $KEY_NAME --yes" 0

    local list_output
    invoke_command "List the encrypted S3 database" "$(get_cli_command) list --db \"$s3_db\" --key $KEY_NAME --yes" 0 "list_output"
    expect_output_string "$list_output" "test.jpg" "The JPG is listed from the encrypted S3 database"
    expect_output_string "$list_output" "test.mp4" "The MP4 is listed from the encrypted S3 database"

    local summary_output
    invoke_command "Summarise the encrypted S3 database" "$(get_cli_command) summary --db \"$s3_db\" --key $KEY_NAME --yes" 0 "summary_output"
    expect_output_string "$summary_output" "Total files:" "Summary contains total files count"

    invoke_command "Verify the encrypted S3 database" "$(get_cli_command) verify --db \"$s3_db\" --key $KEY_NAME --yes" 0

    # --- Without the key, a read must fail loudly. ---

    invoke_command "Remove the encryption key from the vault" \
        "$(get_cli_command) secrets remove --yes --name $KEY_NAME" 0

    local no_key_output
    invoke_command "Listing without the key fails" "$(get_cli_command) list --db \"$s3_db\" --key $KEY_NAME --yes" 1 "no_key_output"
    expect_output_string "$no_key_output" "test.jpg" "No assets are listed without the key" "false"

    test_passed
}

test_s3_encrypted "$TEST_NUMBER"
