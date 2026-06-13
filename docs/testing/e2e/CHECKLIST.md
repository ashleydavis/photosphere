# E2E Test Checklist

Work through these manual tests and check them off as they pass.

Upcoming version: 0.0.8

## Platforms

Run a basic manual test of the CLI and desktop app on each platform.

### CLI
- [x] Linux
- [ ] macOS
- [x] Windows

### Desktop
- [x] Linux (.deb installer)
- [x] Linux (.zip portable)
- [ ] macOS (.dmg installer)
- [ ] macOS (.zip portable)
- [x] Windows (.exe installer)
- [x] Windows (.zip portable)

### UI stories

Open the desktop app at `/#/stories?cycle=1` and check every story cycles through without failures.

- [ ] Linux
- [ ] macOS
- [ ] Windows

## CLI

### Import
- [x] [add-and-verify](cli/import/add-and-verify.md)
- [x] [add-duplicate-content](cli/import/add-duplicate-content.md)
- [x] [add-mp4](cli/import/add-mp4.md)
- [x] [add-multiple-files](cli/import/add-multiple-files.md)
- [x] [add-png](cli/import/add-png.md)
- [x] [add-same-file-twice](cli/import/add-same-file-twice.md)
- [-] [add-zip](cli/import/add-zip.md)
    - This needs testing and needs a smoke test.
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
- [-] [move-file-between-databases](cli/move/move-file-between-databases.md)
    - This command doesn't exist yet.

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
- [x] [add-view-edit-delete](cli/vault/keychain/add-view-edit-delete.md)
- [x] [list-multiple](cli/vault/keychain/list-multiple.md)

### LAN Share
- [x] [share-database](cli/lan-share/share-database.md)
- [x] [share-secret](cli/lan-share/share-secret.md)

### Misc
- [x] [config-timestamps](cli/misc/config-timestamps.md)
- [-] [mcp-server](cli/misc/mcp-server.md)

## Desktop

### Import
- [x] [import-directory](desktop/import/import-directory.md)
    - Problem importing from the zip file
        - Import files have uuid for file name and a wierd path.
        - No immediate need to fix this.
- [x] [import-files](desktop/import/import-files.md)
- [x] [import-video](desktop/import/import-video.md)
    - Video imports, but doesn't play back.
- [-] [import-zip](desktop/import/import-zip.md)
    - This will work but will have a similar problem as above.

### Move
- [x] [move-file-between-databases](desktop/move/move-file-between-databases.md)

### Download
- [x] [download-multiple-assets](desktop/download/download-multiple-assets.md)
- [x] [download-single-asset](desktop/download/download-single-asset.md)

### Replication
- [x] [replicate-full-copy](desktop/replication/replicate-full-copy.md)
- [x] [replicate-partial-copy](desktop/replication/replicate-partial-copy.md)

### Database
- [x] [edit-database-origin](desktop/database/edit-database-origin.md)
- [x] [load-50-asset-fixture](desktop/database/load-50-asset-fixture.md)
- [x] [open-existing-database](desktop/database/open-existing-database.md)
- [x] [remove-recent-database](desktop/database/remove-recent-database.md)
- [x] [view-database-details](desktop/database/view-database-details.md)
- [x] [view-database-secret](desktop/database/view-database-secret.md)

### Secrets
- [-] [add-duplicate-name](desktop/secrets/add-duplicate-name.md)
    - This fails. Clicking Save has no effect for the duplicate secret, no error/toast is shown.
    - It would be good when typing in the duplicate secret name in the Add Secret modal if it shows you in the form that the name is duplicate.
- [x] [add-api-key](desktop/secrets/add-api-key.md)
    - Should not be able to save unless a value is entered. Blank values are useless and should not be allowed.
    - The should be a button that reveals the secret in the input while we are entering it.
- [x] [add-encryption-key](desktop/secrets/add-encryption-key.md)
- [x] [add-s3-credentials](desktop/secrets/add-s3-credentials.md)
- [x] [rename-secret](desktop/secrets/rename-secret.md)
- [x] [view-secret](desktop/secrets/view-secret.md)

### LAN Share
- [x] [share-database](desktop/lan-share/share-database.md)
    - When it tried to create db (with a fake path), the Create Database modal didn't dismiss automatically even though the new db appeared in the Manage Databases list.
- [x] [share-secret](desktop/lan-share/share-secret.md)

### News
- [x] [news-notifications](desktop/news/news-notifications.md)

### MCP
- [-] [mcp-server](desktop/mcp/mcp-server.md)
