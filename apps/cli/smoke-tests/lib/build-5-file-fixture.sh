#!/bin/bash

# Builds the five-file database once for a whole run, so the 18 tests that need one can copy it
# instead of building an identical copy each.
#
# Run from apps/cli with TEST_TMP_DIR pointing at a directory of this run's own:
#   TEST_TMP_DIR=<dir> bash smoke-tests/lib/build-5-file-fixture.sh
#
# It leaves the database at <dir>/db and the UUID counter at <dir>/photosphere-test-uuid-counter,
# which is the pair create_db_with_5_files copies. Building it here rather than in the runner is what
# keeps one definition of what "the five-file database" is: this goes through the same
# populate_db_with_5_files every test used to call.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

FIXTURE_DB_DIR="$TEST_TMP_DIR/db"

invoke_command "Initialize the shared five-file database" "$(get_cli_command) init --db $FIXTURE_DB_DIR --yes"
populate_db_with_5_files "$FIXTURE_DB_DIR"
