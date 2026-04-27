# Smoke Test Function Comparison: Original vs Refactored

Comparing `apps/cli/smoke-tests.sh` (original) against the refactored `smoke-tests/` directory.
Whitespace-only differences are ignored.

## Legend

- **SAME** — identical logic
- **CHANGED** — substantive logic difference

## Table

| # | Function | New File | Status | Differences |
|---|----------|----------|--------|-------------|
| 1 | `test_create_database` | `01-core/test.sh` | SAME | |
| 2 | `test_view_media_files` | `01-core/test.sh` | SAME | |
| 3 | `test_add_file_parameterized` | `01-core/test.sh` | SAME | |
| 4 | `test_add_png_file` | `01-core/test.sh` | SAME | |
| 5 | `test_add_jpg_file` | `01-core/test.sh` | SAME | |
| 6 | `test_add_mp4_file` | `01-core/test.sh` | SAME | |
| 7 | `test_add_same_file` | `01-core/test.sh` | SAME | |
| 8 | `test_add_multiple_files` | `01-core/test.sh` | SAME | |
| 9 | `test_add_same_multiple_files` | `01-core/test.sh` | SAME | |
| 10 | `test_add_duplicate_images` | `01-core/test.sh` | SAME | |
| 11 | `test_database_summary` | `01-core/test.sh` | SAME | |
| 12 | `test_database_list` | `01-core/test.sh` | SAME | |
| 13 | `test_export_assets` | `01-core/test.sh` | SAME | |
| 14 | `test_database_verify` | `01-core/test.sh` | SAME | |
| 15 | `test_database_verify_full` | `01-core/test.sh` | SAME | |
| 16 | `test_detect_deleted_file` | `01-core/test.sh` | SAME | |
| 17 | `test_detect_modified_file` | `01-core/test.sh` | SAME | |
| 18 | `test_database_replicate` | `01-core/test.sh` | SAME | |
| 19 | `test_verify_replica` | `01-core/test.sh` | SAME | |
| 20 | `test_database_replicate_second` | `01-core/test.sh` | SAME | |
| 21 | `test_database_compare` | `01-core/test.sh` | SAME | |
| 22 | `test_compare_with_changes` | `01-core/test.sh` | SAME | |
| 23 | `test_replicate_after_changes` | `01-core/test.sh` | SAME | |
| 24 | `test_cannot_create_over_existing` | `01-core/test.sh` | SAME | |
| 25 | `test_repair_ok_database` | `01-core/test.sh` | SAME | |
| 26 | `test_remove_asset` | `01-core/test.sh` | SAME | |
| 27 | `test_repair_damaged_database` | `01-core/test.sh` | SAME | |
| 28 | `test_v2_database_readonly_commands` | `27-v2-readonly/test.sh` | SAME | |
| 29 | `test_v2_database_write_commands_fail` | `28-v2-write-fail/test.sh` | SAME | |
| 30 | `test_v2_database_upgrade` | `29-v2-upgrade/test.sh` | SAME | |
| 31 | `test_v3_database_upgrade` | `30-v3-upgrade/test.sh` | SAME | |
| 32 | `test_v4_database_upgrade` | `31-v4-upgrade/test.sh` | SAME | |
| 33 | `test_v5_database_upgrade` | `32-v5-upgrade/test.sh` | SAME | |
| 34 | `test_v6_database_upgrade_no_effect` | `33-v6-upgrade-no-effect/test.sh` | SAME | |
| 35 | `test_v6_database_add_file` | `34-v6-add-file/test.sh` | SAME | |
| 36 | `test_sync_original_to_copy` | `35-sync-original-to-copy/test.sh` | SAME | |
| 37 | `test_sync_copy_to_original` | `36-sync-copy-to-original/test.sh` | SAME | |
| 38 | `test_sync_edit_field` | `37-sync-edit-field/test.sh` | SAME | |
| 39 | `test_sync_edit_field_reverse` | `38-sync-edit-field-reverse/test.sh` | SAME | |
| 40 | `test_sync_delete_asset` | `39-sync-delete-asset/test.sh` | SAME | |
| 41 | `test_sync_delete_asset_reverse` | `40-sync-delete-asset-reverse/test.sh` | SAME | |
| 42 | `test_replicate_with_deleted_asset` | `41-replicate-deleted-asset/test.sh` | SAME | |
| 43 | `test_replicate_unrelated_databases_fail` | `42-replicate-unrelated-fail/test.sh` | SAME | |
| 44 | `test_replicate_partial` | `43-replicate-partial/test.sh` | CHANGED | Uses isolated `test_dir` + copies v6 fixture DB instead of shared `$TEST_DB_DIR`; `source_db_dir` replaces `$TEST_DB_DIR` throughout; removes explicit replica cleanup block; adds `rm -rf "$test_dir"` at end |
| 45 | `test_vault_list_shared` | `44-vault-list-shared/test.sh` | SAME | |
| 46 | `test_dbs_list_empty` | `45-dbs-list-empty/test.sh` | SAME | |
| 47 | `test_dbs_add_and_list` | `46-dbs-add-and-list/test.sh` | SAME | |
| 48 | `test_dbs_view` | `47-dbs-view/test.sh` | SAME | |
| 49 | `test_dbs_remove` | `48-dbs-remove/test.sh` | SAME | |
| 50 | `test_dbs_resolve_by_name` | `49-50-dbs-resolve/test.sh` | SAME | |
| 51 | `test_dbs_resolve_by_path` | `49-50-dbs-resolve/test.sh` | SAME | |
| 52 | `test_dbs_no_match_fallback` | `51-dbs-no-match-fallback/test.sh` | SAME | |
| 53 | `test_plaintext_vault_list_empty` | `52-plaintext-vault-list-empty/test.sh` | SAME | |
| 54 | `test_plaintext_vault_add` | `53-plaintext-vault-add/test.sh` | SAME | |
| 55 | `test_plaintext_vault_view` | `54-plaintext-vault-view/test.sh` | SAME | |
| 56 | `test_plaintext_vault_edit` | `55-plaintext-vault-edit/test.sh` | SAME | |
| 57 | `test_plaintext_vault_delete` | `56-plaintext-vault-delete/test.sh` | SAME | |
| 58 | `test_secrets_import` | `57-secrets-import/test.sh` | SAME | |
| 59 | `test_keychain_vault_list_empty` | `58-keychain-vault-list-empty/test.sh` | SAME | |
| 60 | `test_keychain_vault_add` | `59-keychain-vault-add/test.sh` | SAME | |
| 61 | `test_keychain_vault_view` | `60-keychain-vault-view/test.sh` | SAME | |
| 62 | `test_keychain_vault_edit` | `61-keychain-vault-edit/test.sh` | SAME | |
| 63 | `test_keychain_vault_delete` | `62-keychain-vault-delete/test.sh` | SAME | |
| 64 | `test_keychain_vault_list_multiple` | `63-keychain-vault-list-multiple/test.sh` | SAME | |
| 65 | `test_dbs_edit` | `64-dbs-edit/test.sh` | SAME | |
| 66 | `test_dbs_add_cli` | `65-dbs-add-cli/test.sh` | SAME | |
| 67 | `test_dbs_add_duplicate` | `66-dbs-add-duplicate/test.sh` | SAME | |
| 68 | `test_secrets_add_duplicate` | `67-secrets-add-duplicate/test.sh` | SAME | |
| 69 | `test_dbs_clear` | `68-dbs-clear/test.sh` | SAME | |
| 70 | `test_secrets_clear` | `69-secrets-clear/test.sh` | CHANGED | `reset_environment()` that followed `test_secrets_clear` in the original has been removed from this file — it was moved to `smoke-tests/lib/common.sh` |

## Summary

- **68 SAME**: all functions are logically identical
- **1 logic change**: `test_replicate_partial` — refactored to be self-contained using an isolated temp dir and v6 fixture database instead of the shared `$TEST_DB_DIR`
- **1 structural change**: `test_secrets_clear` — `reset_environment()` was moved out to `lib/common.sh`
