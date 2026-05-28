# E2E Test Checklist

Work through these manual tests and check them off as they pass.

## CLI

### Import
- [ ] [add-and-verify](cli/import/add-and-verify.md)
- [ ] [add-duplicate-content](cli/import/add-duplicate-content.md)
- [ ] [add-mp4](cli/import/add-mp4.md)
- [ ] [add-multiple-files](cli/import/add-multiple-files.md)
- [ ] [add-png](cli/import/add-png.md)
- [ ] [add-same-file-twice](cli/import/add-same-file-twice.md)
- [ ] [no-overwrite-existing-database](cli/import/no-overwrite-existing-database.md)

### Inspect
- [ ] [database-summary](cli/inspect/database-summary.md)
- [ ] [export-asset](cli/inspect/export-asset.md)

### Verify
- [ ] [detect-deleted-file](cli/verify/detect-deleted-file.md)
- [ ] [detect-modified-file](cli/verify/detect-modified-file.md)
- [ ] [repair-clean-database](cli/verify/repair-clean-database.md)
- [ ] [repair-damaged-database](cli/verify/repair-damaged-database.md)
- [ ] [verify-full](cli/verify/verify-full.md)

### Remove
- [ ] [remove-asset-by-id](cli/remove/remove-asset-by-id.md)

### Compare
- [ ] [compare-after-changes](cli/compare/compare-after-changes.md)
- [ ] [compare-identical](cli/compare/compare-identical.md)

### Sync
- [ ] [sync-copy-to-original](cli/sync/sync-copy-to-original.md)
- [ ] [sync-delete-asset-copy](cli/sync/sync-delete-asset-copy.md)
- [ ] [sync-delete-asset-original](cli/sync/sync-delete-asset-original.md)
- [ ] [sync-edit-field-copy](cli/sync/sync-edit-field-copy.md)
- [ ] [sync-edit-field-original](cli/sync/sync-edit-field-original.md)
- [ ] [sync-original-to-copy](cli/sync/sync-original-to-copy.md)

### Move
- [ ] [move-file-between-databases](cli/move/move-file-between-databases.md)

### Replication
- [ ] [replicate-deleted-asset](cli/replication/replicate-deleted-asset.md)
- [ ] [replicate-full-copy](cli/replication/replicate-full-copy.md)
- [ ] [replicate-incremental-changes](cli/replication/replicate-incremental-changes.md)
- [ ] [replicate-no-changes](cli/replication/replicate-no-changes.md)
- [ ] [replicate-partial-copy](cli/replication/replicate-partial-copy.md)
- [ ] [replicate-unrelated-fails](cli/replication/replicate-unrelated-fails.md)

### Upgrade
- [ ] [add-file-after-upgrade](cli/upgrade/add-file-after-upgrade.md)
- [ ] [upgrade-v2-to-v6](cli/upgrade/upgrade-v2-to-v6.md)
- [ ] [upgrade-v3-to-v6](cli/upgrade/upgrade-v3-to-v6.md)
- [ ] [upgrade-v4-to-v6](cli/upgrade/upgrade-v4-to-v6.md)
- [ ] [upgrade-v5-to-v6](cli/upgrade/upgrade-v5-to-v6.md)
- [ ] [v2-readonly](cli/upgrade/v2-readonly.md)
- [ ] [v2-write-fails](cli/upgrade/v2-write-fails.md)
- [ ] [v6-upgrade-noop](cli/upgrade/v6-upgrade-noop.md)

### Databases (dbs)
- [ ] [add-and-list](cli/dbs/add-and-list.md)
- [ ] [add-duplicate-fails](cli/dbs/add-duplicate-fails.md)
- [ ] [add-via-flags](cli/dbs/add-via-flags.md)
- [ ] [clear](cli/dbs/clear.md)
- [ ] [edit-rename](cli/dbs/edit-rename.md)
- [ ] [list-empty](cli/dbs/list-empty.md)
- [ ] [no-match-fallback](cli/dbs/no-match-fallback.md)
- [ ] [remove](cli/dbs/remove.md)
- [ ] [resolve-by-name](cli/dbs/resolve-by-name.md)
- [ ] [resolve-by-path](cli/dbs/resolve-by-path.md)
- [ ] [view](cli/dbs/view.md)

### Vault (plaintext)
- [ ] [add-duplicate-fails](cli/vault/plaintext/add-duplicate-fails.md)
- [ ] [add-secret](cli/vault/plaintext/add-secret.md)
- [ ] [clear](cli/vault/plaintext/clear.md)
- [ ] [delete-secret](cli/vault/plaintext/delete-secret.md)
- [ ] [edit-secret](cli/vault/plaintext/edit-secret.md)
- [ ] [import-pem](cli/vault/plaintext/import-pem.md)
- [ ] [list-empty](cli/vault/plaintext/list-empty.md)
- [ ] [list-shared](cli/vault/plaintext/list-shared.md)
- [ ] [view-secret](cli/vault/plaintext/view-secret.md)

### Vault (keychain)
- [ ] [add-view-edit-delete](cli/vault/keychain/add-view-edit-delete.md)
- [ ] [list-multiple](cli/vault/keychain/list-multiple.md)

### LAN Share
- [ ] [share-database](cli/lan-share/share-database.md)
- [ ] [share-secret](cli/lan-share/share-secret.md)

### Misc
- [ ] [config-timestamps](cli/misc/config-timestamps.md)
- [ ] [mcp-server](cli/misc/mcp-server.md)

---

## Desktop

### Import
- [ ] [add-and-verify](desktop/import/add-and-verify.md)

### Move
- [ ] [move-file-between-databases](desktop/move/move-file-between-databases.md)

### Download
- [ ] [download-multiple-assets](desktop/download/download-multiple-assets.md)
- [ ] [download-single-asset](desktop/download/download-single-asset.md)

### Replication
- [ ] [replicate-full-copy](desktop/replication/replicate-full-copy.md)
- [ ] [replicate-partial-copy](desktop/replication/replicate-partial-copy.md)

### Database
- [ ] [add-external-database](desktop/database/add-external-database.md)
- [ ] [edit-database-origin](desktop/database/edit-database-origin.md)
- [ ] [load-50-asset-fixture](desktop/database/load-50-asset-fixture.md)
- [ ] [open-existing-database](desktop/database/open-existing-database.md)
- [ ] [remove-recent-database](desktop/database/remove-recent-database.md)
- [ ] [view-database-details](desktop/database/view-database-details.md)

### Secrets
- [ ] [add-duplicate-name](desktop/secrets/add-duplicate-name.md)
- [ ] [add-secret](desktop/secrets/add-secret.md)
- [ ] [edit-api-key](desktop/secrets/edit-api-key.md)
- [ ] [edit-encryption-key](desktop/secrets/edit-encryption-key.md)
- [ ] [edit-s3-credentials](desktop/secrets/edit-s3-credentials.md)
- [ ] [rename-secret](desktop/secrets/rename-secret.md)
- [ ] [view-secret](desktop/secrets/view-secret.md)

### LAN Share
- [ ] [share-database](desktop/lan-share/share-database.md)
- [ ] [share-secret](desktop/lan-share/share-secret.md)

### News
- [ ] [news-notifications](desktop/news/news-notifications.md)

### MCP
- [ ] [mcp-server](desktop/mcp/mcp-server.md)
