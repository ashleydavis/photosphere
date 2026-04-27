# CLI Smoke Test Separation into Individual Scripts

## Overview
The CLI smoke test suite is a single monolithic script (`apps/cli/smoke-tests.sh`) of ~4865 lines containing 69 tests. This plan refactors it so each test (or indivisible group of tests) lives in its own script file under `apps/cli/smoke-tests/`. The existing `smoke-tests.sh` becomes an orchestrator that discovers and delegates to these scripts while preserving the existing command-line interface exactly: `./smoke-tests.sh`, `./smoke-tests.sh all`, `./smoke-tests.sh X` (by number or name), and `./smoke-tests.sh to X`. Tests continue to run sequentially in the same order as today.

## Issues

## Steps

### 1. Create shared library: `apps/cli/smoke-tests/lib/common.sh`
Extract from `smoke-tests.sh` all shared utility functions that every test script will need:
- Color variables and `log_info`, `log_success`, `log_error`, `log_warning`
- `print_test_header`
- `invoke_command`
- `check_exists`, `check_empty`
- `expect_value`, `expect_output_value`, `expect_output_string`
- `parse_numeric`
- `expect_image`, `expect_video`, `validate_database_assets`
- `get_cli_command`, `get_mk_command`, `get_bdb_command`
- `detect_platform`, `detect_architecture`
- `check_merkle_tree_order`, `verify_root_hashes_match`
- `test_passed`, `test_failed`
- `show_tree`, `count_files_in_summary`
- `seed_vault_secret`, `seed_databases_config`
- Environment variable defaults: `TEST_TMP_DIR`, `TEST_DB_DIR`, `TEST_FILES_DIR`, `MULTIPLE_IMAGES_DIR`, `DUPLICATE_IMAGES_DIR`, `PHOTOSPHERE_VAULT_DIR`, `PHOTOSPHERE_CONFIG_DIR`, `PHOTOSPHERE_VAULT_TYPE`, `USE_BINARY`, `NO_COLOR`, `NODE_ENV`
- The `TESTS_PASSED`, `TESTS_FAILED`, `FAILED_TESTS` accumulators and the `cleanup_and_show_summary` trap

The library sets `SMOKE_TESTS_DIR` to `$(dirname "${BASH_SOURCE[0]}")/..` so every consumer gets the correct base path.

### 2. Create `apps/cli/smoke-tests/01-core/test.sh` — tests 1–26
This is the indivisible group. Copy these 26 test functions **verbatim and unchanged** from `smoke-tests.sh` into this file:
`test_create_database`, `test_view_media_files`, `test_add_png_file`, `test_add_jpg_file`, `test_add_mp4_file`, `test_add_same_file`, `test_add_multiple_files`, `test_add_same_multiple_files`, `test_add_duplicate_images`, `test_database_summary`, `test_database_list`, `test_export_assets`, `test_database_verify`, `test_database_verify_full`, `test_detect_deleted_file`, `test_detect_modified_file`, `test_database_replicate`, `test_verify_replica`, `test_database_replicate_second`, `test_database_compare`, `test_compare_with_changes`, `test_replicate_after_changes`, `test_cannot_create_over_existing`, `test_repair_ok_database`, `test_remove_asset`, `test_repair_damaged_database`.

These remain 26 separate, individually-named test functions — they are **not merged** into one. The only new code added to this file is the boilerplate that sources `lib/common.sh` and calls each function in sequence (passing the global test number 1–26), exactly as the existing `run_all_tests` loop does today. Each function still calls `test_passed`/`test_failed` independently. The script exits 0 on success, non-zero on failure.

Tests 1–26 share `TEST_DB_DIR` and `TEST_DB_DIR-replica` state and must run in this fixed sequence, which is why they form one script.

### 3. Create individual scripts for tests 27–42 (version upgrade and sync)
Each script lives at `apps/cli/smoke-tests/NN-name/test.sh`, sources `../../lib/common.sh`, runs its single test function, and exits. These tests each create their own isolated temporary databases and clean up, so they have no dependency on `01-core`.

Scripts to create (test number → directory name → function):
- `27-v2-readonly` → `test_v2_database_readonly_commands`
- `28-v2-write-fail` → `test_v2_database_write_commands_fail`
- `29-v2-upgrade` → `test_v2_database_upgrade`
- `30-v3-upgrade` → `test_v3_database_upgrade`
- `31-v4-upgrade` → `test_v4_database_upgrade`
- `32-v5-upgrade` → `test_v5_database_upgrade`
- `33-v6-upgrade-no-effect` → `test_v6_database_upgrade_no_effect`
- `34-v6-add-file` → `test_v6_database_add_file`
- `35-sync-original-to-copy` → `test_sync_original_to_copy`
- `36-sync-copy-to-original` → `test_sync_copy_to_original`
- `37-sync-edit-field` → `test_sync_edit_field`
- `38-sync-edit-field-reverse` → `test_sync_edit_field_reverse`
- `39-sync-delete-asset` → `test_sync_delete_asset`
- `40-sync-delete-asset-reverse` → `test_sync_delete_asset_reverse`
- `41-replicate-deleted-asset` → `test_replicate_with_deleted_asset`
- `42-replicate-unrelated-fail` → `test_replicate_unrelated_databases_fail`

### 4. Create `apps/cli/smoke-tests/43-replicate-partial/test.sh`
Extract `test_replicate_partial` with one targeted change to remove its dependency on `TEST_DB_DIR`: instead of using the shared database built by the core group as the replication source, copy `../../test/dbs/v6` to an isolated temp directory (same pattern as `test_v6_add_file`, `test_sync_original_to_copy`, etc.) and use that as the source. Replace the `$TEST_DB_DIR` and `$TEST_DB_DIR-partial-replica` references with the temp paths and clean up at the end. All assertions remain identical — the test only compares the replica against whatever source it was given, so it works correctly with any populated database. The script sources `../../lib/common.sh` and runs `test_replicate_partial 43`.

### 5. Create individual scripts for tests 44–51 (vault and database management)
- `44-vault-list-shared` → `test_vault_list_shared`
- `45-dbs-list-empty` → `test_dbs_list_empty`
- `46-dbs-add-and-list` → `test_dbs_add_and_list`
- `47-dbs-view` → `test_dbs_view`
- `48-dbs-remove` → `test_dbs_remove`
- `49-50-dbs-resolve` → contains both `test_dbs_resolve_by_name` (49) and `test_dbs_resolve_by_path` (50), because test 50 reuses the database created by test 49 at `$TEST_TMP_DIR/dbs-resolve-name/db`
- `51-dbs-no-match-fallback` → `test_dbs_no_match_fallback`

### 6. Create individual scripts for tests 52–65 (secrets and dbs CLI)
- `52-plaintext-vault-list-empty` → `test_plaintext_vault_list_empty`
- `53-plaintext-vault-add` → `test_plaintext_vault_add`
- `54-plaintext-vault-view` → `test_plaintext_vault_view`
- `55-plaintext-vault-edit` → `test_plaintext_vault_edit`
- `56-plaintext-vault-delete` → `test_plaintext_vault_delete`
- `57-secrets-import` → `test_secrets_import`
- `58-keychain-vault-list-empty` → `test_keychain_vault_list_empty`
- `59-keychain-vault-add` → `test_keychain_vault_add`
- `60-keychain-vault-view` → `test_keychain_vault_view`
- `61-keychain-vault-edit` → `test_keychain_vault_edit`
- `62-keychain-vault-delete` → `test_keychain_vault_delete`
- `63-keychain-vault-list-multiple` → `test_keychain_vault_list_multiple`
- `64-dbs-edit` → `test_dbs_edit`
- `65-dbs-add-cli` → `test_dbs_add_cli`
- `66-dbs-add-duplicate` → `test_dbs_add_duplicate`
- `67-secrets-add-duplicate` → `test_secrets_add_duplicate`
- `68-dbs-clear` → `test_dbs_clear`
- `69-secrets-clear` → `test_secrets_clear`

### 7. Refactor `smoke-tests.sh` into an orchestrator
Keep in `smoke-tests.sh`:
- The `TEST_TABLE` array (unchanged) — it is the source of truth for test names, numbers, and descriptions
- The existing `main()` entry point and all command-line parsing (`--binary`, `--tmp-dir`, `to X`, single test by number/name, `all`, `setup`, `check-tools`, `reset`, `show_usage`)
- `test_setup` and `check_tools` functions (these are not individual tests; they remain inline)
- `reset_environment` and `run_multiple_commands`

Remove from `smoke-tests.sh`: all test functions and all shared utility functions (now in `lib/common.sh` or individual scripts).

Add to `smoke-tests.sh`:
- `discover_tests` — `find smoke-tests -name "test.sh" | sort -V` (same pattern as Electron smoke tests)
- `get_script_for_test N` — maps a test number to the script that contains it. Tests 1–26 map to `smoke-tests/01-core/test.sh`; test 43 maps to `smoke-tests/43-replicate-partial/test.sh`; tests 49–50 map to `smoke-tests/49-50-dbs-resolve/test.sh`; all others map 1:1.
- `run_script SCRIPT_PATH TEST_NUMBER` — invokes the script, captures exit code, and records pass/fail
- Update `run_all_tests` to: (a) run `01-core` first, then (b) run all remaining discovered scripts in numerical order
- Update `run_test NAME_OR_NUMBER` to: resolve to a script path via `get_script_for_test`, then run it
- Update `to X` to: collect distinct script paths for tests 1–X in order, then run them

### 8. Verify the TEST_TABLE stays the source of truth
The orchestrator still uses `TEST_TABLE` for `show_usage` (listing all test names and descriptions), and for resolving `./smoke-tests.sh create-database` by name to the correct script. The `test_number` passed to each test function is derived from the test's position in `TEST_TABLE`.

## Unit Tests
No TypeScript code is changed, so no unit tests to add or update.

## Smoke Tests
- `cd apps/cli && ./smoke-tests.sh` — all tests pass in sequence
- `cd apps/cli && ./smoke-tests.sh all` — same
- `cd apps/cli && ./smoke-tests.sh create-database` — runs only 01-core (the core group, since test 1 is inside it)
- `cd apps/cli && ./smoke-tests.sh 27` — runs only test 27 (v2-readonly)
- `cd apps/cli && ./smoke-tests.sh v2-readonly` — same as above, by name
- `cd apps/cli && ./smoke-tests.sh to 5` — runs 01-core (the script containing tests 1–26; running more than 5 tests is acceptable for tests inside the core group)
- `cd apps/cli && ./smoke-tests.sh to 30` — runs 01-core, 27, 28, 29, 30 in order
- `cd apps/cli && ./smoke-tests.sh 50` — runs the `49-50-dbs-resolve` script (both tests 49 and 50)
- Each individual `smoke-tests/NN-name/test.sh` can be run directly with `bash smoke-tests/27-v2-readonly/test.sh`

## Verify
- `cd apps/cli && ./smoke-tests.sh` completes with `ALL SMOKE TESTS PASSED`
- `cd apps/cli && ./smoke-tests.sh 27` runs and passes independently
- `cd apps/cli && ./smoke-tests.sh to 10` runs and passes (01-core only)
- Each test script can be executed standalone: `bash apps/cli/smoke-tests/27-v2-readonly/test.sh`

## Notes
- **Core group boundary**: Tests 1–26 are the minimum set that must stay together. Test 43 (`replicate-partial`) is made fully independent by switching its source database from `TEST_DB_DIR` to a copy of the v6 fixture, so it requires no prior state from `01-core`.
- **Tests 49–50 dependency**: `dbs-resolve-by-path` reuses a database directory created by `dbs-resolve-by-name` at `$TEST_TMP_DIR/dbs-resolve-name/db`. They share one script and cannot be individually isolated without modifying test content.
- **Maximum code preservation**: Every test function body — in every script — must be copied verbatim from `smoke-tests.sh`. No logic, variable names, assertions, or output strings may be altered unless a change is strictly required for the function to work in its new location (e.g. updating a relative path to `lib/common.sh`). The goal is that a diff of any moved function against the original shows only whitespace or path changes.
- **Test function names are preserved**: Every test function keeps its exact original name (e.g. `test_v2_database_readonly_commands`, `test_sync_original_to_copy`). Names must not be shortened, renamed, or reformatted.
- **Backward compatibility**: The `TEST_TABLE` array and all existing CLI options remain unchanged, so CI scripts invoking `smoke-tests.sh` continue to work.
- **`to X` for X in 1–26**: The command runs `01-core` (all 26 tests), which may run more tests than the number X implies. This is a documented trade-off of the grouping.
