# E2E Test Checklist

Work through these manual tests and check them off as they pass.

Upcoming version: 0.0.8

## CLI

### Import
- [x] [add-and-verify](cli/import/add-and-verify.md)
- [x] [add-duplicate-content](cli/import/add-duplicate-content.md)
- [x] [add-mp4](cli/import/add-mp4.md)
- [x] [add-multiple-files](cli/import/add-multiple-files.md)
- [x] [add-png](cli/import/add-png.md)
- [x] [add-same-file-twice](cli/import/add-same-file-twice.md)
- [ ] [add-zip](cli/import/add-zip.md)
- [x] [no-overwrite-existing-database](cli/import/no-overwrite-existing-database.md)

### Inspect
- [x] [database-summary](cli/inspect/database-summary.md)
- [x] [export-asset](cli/inspect/export-asset.md)

### Verify
- [x] [detect-deleted-file](cli/verify/detect-deleted-file.md)
- [x] [detect-modified-file](cli/verify/detect-modified-file.md)
- [x] [repair-clean-database](cli/verify/repair-clean-database.md)
- [x] [repair-damaged-database](cli/verify/repair-damaged-database.md)
- [x] [verify-full](cli/verify/verify-full.md)

### Remove
- [x] [remove-asset-by-id](cli/remove/remove-asset-by-id.md)

### Compare
- [x] [compare-after-changes](cli/compare/compare-after-changes.md)
- [x] [compare-identical](cli/compare/compare-identical.md)

### Sync
- [x] [sync-copy-to-original](cli/sync/sync-copy-to-original.md)
- [x] [sync-delete-asset-copy](cli/sync/sync-delete-asset-copy.md)
- [x] [sync-delete-asset-original](cli/sync/sync-delete-asset-original.md)
- [x] [sync-edit-field-copy](cli/sync/sync-edit-field-copy.md)
- [x] [sync-edit-field-original](cli/sync/sync-edit-field-original.md)
- [x] [sync-original-to-copy](cli/sync/sync-original-to-copy.md)

### Move
- [ ] [move-file-between-databases](cli/move/move-file-between-databases.md)

### Replication
- [x] [replicate-deleted-asset](cli/replication/replicate-deleted-asset.md)
- [x] [replicate-full-copy](cli/replication/replicate-full-copy.md)
- [x] [replicate-incremental-changes](cli/replication/replicate-incremental-changes.md)
- [x] [replicate-no-changes](cli/replication/replicate-no-changes.md)
- [x] [replicate-partial-copy](cli/replication/replicate-partial-copy.md)
- [x] [replicate-unrelated-fails](cli/replication/replicate-unrelated-fails.md)

### Upgrade
- [x] [add-file-after-upgrade](cli/upgrade/add-file-after-upgrade.md)
- [x] [upgrade-v2-to-v6](cli/upgrade/upgrade-v2-to-v6.md)
- [x] [upgrade-v3-to-v6](cli/upgrade/upgrade-v3-to-v6.md)
- [x] [upgrade-v4-to-v6](cli/upgrade/upgrade-v4-to-v6.md)
- [x] [upgrade-v5-to-v6](cli/upgrade/upgrade-v5-to-v6.md)
- [x] [v2-readonly](cli/upgrade/v2-readonly.md)
- [x] [v2-write-fails](cli/upgrade/v2-write-fails.md)
- [x] [v6-upgrade-noop](cli/upgrade/v6-upgrade-noop.md)

### Databases (dbs)
- [x] [add-and-list](cli/dbs/add-and-list.md)
- [x] [add-duplicate-fails](cli/dbs/add-duplicate-fails.md)
- [x] [add-via-flags](cli/dbs/add-via-flags.md)
- [x] [clear](cli/dbs/clear.md)
- [x] [edit-rename](cli/dbs/edit-rename.md)
- [x] [list-empty](cli/dbs/list-empty.md)
- [x] [no-match-fallback](cli/dbs/no-match-fallback.md)
- [x] [remove](cli/dbs/remove.md)
- [x] [resolve-by-name](cli/dbs/resolve-by-name.md)
- [x] [resolve-by-path](cli/dbs/resolve-by-path.md)
- [x] [view](cli/dbs/view.md)

### Vault (plaintext)
- [x] [add-duplicate-fails](cli/vault/plaintext/add-duplicate-fails.md)
- [x] [add-secret](cli/vault/plaintext/add-secret.md)
- [x] [clear](cli/vault/plaintext/clear.md)
- [x] [delete-secret](cli/vault/plaintext/delete-secret.md)
- [x] [edit-secret](cli/vault/plaintext/edit-secret.md)
- [x] [import-pem](cli/vault/plaintext/import-pem.md)
- [x] [list-empty](cli/vault/plaintext/list-empty.md)
- [x] [list-shared](cli/vault/plaintext/list-shared.md)
- [x] [view-secret](cli/vault/plaintext/view-secret.md)

### Vault (keychain)
- [ ] [add-view-edit-delete](cli/vault/keychain/add-view-edit-delete.md)
- [ ] [list-multiple](cli/vault/keychain/list-multiple.md)

### LAN Share
- [ ] [share-database](cli/lan-share/share-database.md)
- [ ] [share-secret](cli/lan-share/share-secret.md)

### Misc
- [x] [config-timestamps](cli/misc/config-timestamps.md)
- [ ] [mcp-server](cli/misc/mcp-server.md)

---

## Desktop

### Import
- [ ] [import-directory](desktop/import/import-directory.md)
- [x] [import-files](desktop/import/import-files.md)
- [ ] [import-video](desktop/import/import-video.md)
- [ ] [import-zip](desktop/import/import-zip.md)

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
