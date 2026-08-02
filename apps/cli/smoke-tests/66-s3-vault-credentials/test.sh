#!/bin/bash
DESCRIPTION="S3 database using credentials from a vault secret"

# Covers the vault branch of resolveStorageCredentials
# (packages/node-api/src/lib/resolve-storage-credentials.ts lines 63-83), which is the credential path
# the desktop and mobile apps actually use, and which no other test exercises: test 65 covers the
# AWS_* environment-variable branch only.
#
# The test runs in three parts:
#
#   1. Create the database on S3 with AWS_* credentials, then UNSET them. Everything after that point
#      addresses the database by name with no AWS_* variable set anywhere, so the only place the
#      credentials exist is the vault secret named by the databases.json entry. A database that reads
#      back its asset therefore proves the vault branch resolved and reached the server.
#   2. Break the stored access key and assert a read fails loudly. An empty-but-successful listing
#      there is indistinguishable from an empty database, which is how a broken credential quietly
#      looks like no data.
#   3. Assert that creating an S3 database whose credential lives only in the vault works at all.
#
# Part 3 currently FAILS, and is left failing on purpose. `configureS3IfNeeded`
# (apps/cli/src/lib/init-cmd.ts lines 66-80) gates on AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY or a
# 'default:s3' keychain secret and never consults the databases.json entry's s3Key, so in
# non-interactive mode `init` on an s3: path refuses with "S3 credentials are required" even though
# every read command resolves the same database's credentials from the vault without trouble. The
# same call gates replicate, sync, encrypt and decrypt.
#
# resolveStorageCredentials matches the databases.json entry on an exact `path` string, so the path
# registered with `dbs add` and the path the commands resolve to must be byte-identical; addressing
# by name is what guarantees that.
#
# Note also that `psi init --db <registered-name>` does not resolve a registered name at all:
# createDatabase (apps/cli/src/lib/init-cmd.ts line 926) takes options.db as a directory path
# verbatim, so it creates a LOCAL directory called "<name>" in the working directory and reports
# success. That is why this test never passes a name to init.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TEST_NUMBER="${1:-66}"
S3_STATE_DIR="$(get_test_dir "$TEST_NUMBER")/s3"
SECRET_NAME="s3cred66"
DB_NAME="s3-vault-db"

# Stop the app's summary printer AND the emulator, so a failed assertion never leaves a MinIO server
# running. The emulator's stop is safe to call when nothing was started, so it goes in
# unconditionally.
cleanup_s3_and_show_summary() {
    local exit_code=$?
    stop_s3_emulator "$S3_STATE_DIR"
    return $exit_code
}
trap 'cleanup_s3_and_show_summary; cleanup_and_show_summary' EXIT

test_s3_vault_credentials() {
    local test_number="$1"
    print_test_header "$test_number" "S3 VAULT CREDENTIALS"

    start_s3_emulator "$S3_STATE_DIR"

    seed_s3_vault_secret "$SECRET_NAME"

    local s3_db="s3:$S3_EMULATOR_BUCKET/vault-cred-test"
    log_info "Database path: $s3_db"

    # Start from an empty database list. The per-test scratch directory survives between runs of a
    # single test, so a leftover entry from the last run would make `dbs add` fail as a duplicate.
    seed_databases_config "[]"

    invoke_command "Register the S3 database with its vault credential" \
        "$(get_cli_command) dbs add --yes --name $DB_NAME --path \"$s3_db\" --s3-cred $SECRET_NAME" 0

    # --- 1. Read and write the database through the vault credential alone. ---

    # Creating the database needs the environment credentials because of the init defect described in
    # the header. They are unset immediately afterwards so nothing below can fall back to them.
    export_s3_env_credentials
    invoke_command "Initialize the database on S3" "$(get_cli_command) init --db \"$s3_db\" --yes" 0
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_ENDPOINT AWS_REGION

    invoke_command "Add an image to the database by name" \
        "$(get_cli_command) add $TEST_FILES_DIR/test.jpg --db $DB_NAME --yes" 0

    local summary_output
    invoke_command "Summarise the database by name" "$(get_cli_command) summary --db $DB_NAME --yes" 0 "summary_output"
    expect_output_string "$summary_output" "Total files:" "Summary contains total files count"

    # The imported asset must appear by name. This is what fails if the credentials never resolved and
    # the database read back empty.
    local list_output
    invoke_command "List the database's assets by name" "$(get_cli_command) list --db $DB_NAME --yes" 0 "list_output"
    expect_output_string "$list_output" "test.jpg" "The imported asset is listed from S3 via the vault credential"

    # --- 2. A broken credential must fail loudly, not read back an empty database. ---

    invoke_command "Break the stored access key" \
        "$(get_cli_command) secrets edit --yes --name $SECRET_NAME --value '{\"region\":\"us-east-1\",\"accessKeyId\":\"WRONGACCESSKEY\",\"secretAccessKey\":\"WRONGSECRETKEY\",\"endpoint\":\"$S3_ENDPOINT\"}'" 0

    local broken_list_output
    invoke_command "List with a broken credential fails" "$(get_cli_command) list --db $DB_NAME --yes" 1 "broken_list_output"
    expect_output_string "$broken_list_output" "test.jpg" "A broken credential lists no assets" "false"

    # --- 3. Creating an S3 database from a vault credential alone. ---

    # Restore a working credential, then create a second database at a fresh prefix with no AWS_*
    # variable set. This is the assertion the init defect fails; it is last so everything above still
    # runs and reports.
    seed_s3_vault_secret "$SECRET_NAME"

    local second_db="s3:$S3_EMULATOR_BUCKET/vault-cred-test-2"
    invoke_command "Register a second S3 database with the same vault credential" \
        "$(get_cli_command) dbs add --yes --name ${DB_NAME}-2 --path \"$second_db\" --s3-cred $SECRET_NAME" 0

    invoke_command "Initialize an S3 database whose credential is only in the vault" \
        "$(get_cli_command) init --db \"$second_db\" --yes" 0

    test_passed
}

test_s3_vault_credentials "$TEST_NUMBER"
