# E2E Test Checklist

**Do not skip steps.** Every test linked below is run in full, every step, in the order it is written. An agent taking someone through a test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Work through these manual tests and check them off as they pass.

Upcoming version: 0.0.9

## Platforms

Run a basic manual test of the CLI and desktop app on each platform.

### CLI
- [ ] Linux
- [ ] macOS
- [ ] Windows

### Mobile
- [ ] Android
- [ ] iOS

### Desktop
- [ ] Linux (.deb installer)
- [ ] Linux (.zip portable)
- [ ] macOS (.dmg installer)
- [ ] macOS (.zip portable) - there is none for x86 yet.
- [ ] Windows (.exe installer)
- [ ] Windows (.zip portable)

### UI stories

Run the story player and check every story cycles through without failures, then review the generated screenshot index for pages that look wrong or do not fit the screen. `bun run stories` (Electron), `bun run stories:and`, `bun run stories:ios`. See [the stories README](../../../packages/user-interface/src/stories/README.md).

- [ ] Linux
- [ ] macOS
- [ ] Windows
- [ ] Android
- [ ] iOS

## CLI

### Import
- [ ] [add-and-verify](cli/import/add-and-verify.md)
- [ ] [add-duplicate-content](cli/import/add-duplicate-content.md)
- [ ] [add-mp4](cli/import/add-mp4.md)
- [ ] [add-multiple-files](cli/import/add-multiple-files.md)
- [ ] [add-png](cli/import/add-png.md)
- [ ] [add-same-file-twice](cli/import/add-same-file-twice.md)
- [ ] [add-zip](cli/import/add-zip.md)
    - This needs testing and needs a smoke test.
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
    - This command doesn't exist yet.

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

## Desktop

### Import
- [ ] [import-directory](desktop/import/import-directory.md)
    - Problem importing from the zip file
        - Import files have uuid for file name and a wierd path.
        - No immediate need to fix this.
- [ ] [import-files](desktop/import/import-files.md)
- [ ] [import-video](desktop/import/import-video.md)
    - Video imports, but doesn't play back.
- [ ] [import-zip](desktop/import/import-zip.md)
    - This will work but will have a similar problem as above.

### Move
- [ ] [move-file-between-databases](desktop/move/move-file-between-databases.md)

### Download
- [ ] [download-multiple-assets](desktop/download/download-multiple-assets.md)
- [ ] [download-single-asset](desktop/download/download-single-asset.md)

### Replication
- [ ] [replicate-full-copy](desktop/replication/replicate-full-copy.md)
- [ ] [replicate-partial-copy](desktop/replication/replicate-partial-copy.md)

### Database
- [ ] [edit-database-origin](desktop/database/edit-database-origin.md)
- [ ] [load-50-asset-fixture](desktop/database/load-50-asset-fixture.md)
- [ ] [open-existing-database](desktop/database/open-existing-database.md)
- [ ] [remove-recent-database](desktop/database/remove-recent-database.md)
- [ ] [view-database-details](desktop/database/view-database-details.md)
- [ ] [view-database-secret](desktop/database/view-database-secret.md)

### Secrets
- [ ] [add-duplicate-name](desktop/secrets/add-duplicate-name.md)
    - This fails. Clicking Save has no effect for the duplicate secret, no error/toast is shown.
    - It would be good when typing in the duplicate secret name in the Add Secret modal if it shows you in the form that the name is duplicate.
- [ ] [add-api-key](desktop/secrets/add-api-key.md)
    - Should not be able to save unless a value is entered. Blank values are useless and should not be allowed.
    - The should be a button that reveals the secret in the input while we are entering it.
- [ ] [add-encryption-key](desktop/secrets/add-encryption-key.md)
- [ ] [add-s3-credentials](desktop/secrets/add-s3-credentials.md)
- [ ] [rename-secret](desktop/secrets/rename-secret.md)
- [ ] [view-secret](desktop/secrets/view-secret.md)

### LAN Share
- [ ] [share-database](desktop/lan-share/share-database.md)
    - When it tried to create db (with a fake path), the Create Database modal didn't dismiss automatically even though the new db appeared in the Manage Databases list.
- [ ] [share-secret](desktop/lan-share/share-secret.md)

### News
- [ ] [news-notifications](desktop/news/news-notifications.md)

### MCP
- [ ] [mcp-server](desktop/mcp/mcp-server.md)

## Mobile

Run each of these on Android and on iOS. Tick a test only when it has passed on both, and say which platform failed when one does.

### Automatic import
- [ ] [auto-import-full-flow](mobile/auto-import/auto-import-full-flow.md)
    - *n* Step 6 fails: the import record doesn't load as new imports are added. The Import page reads the record once, when the database is opened, and never again, so a database opened before automatic import ran shows an empty list however many photos have gone in since.
    - *e* Android: works, but too slowly to call a pass. Steps 1 to 4 passed. Step 5: a photo taken at 07:06 did not appear until about 07:48, so 42 minutes instead of a few seconds.
    - High priority
        - *e* A photo just taken must show up within 3 seconds. It took 42 minutes. New photos must take priority over importing the existing library: right now the import loop only looks for new photos between batches, and a batch of up to 60 old photos takes ten minutes or more, so a new photo is not even noticed until that finishes. The batch size must be much, much smaller than 60.
        - *e* Increase the number of workers on mobile to 10.
    - Medium priority
        - *e* Hashing never hits the cache: 143 out of 143 hashes were computed from scratch. Each photo is copied out of the device library into a temp file before it is hashed, and the cache is keyed on the file path, size and last modified time, so a fresh copy never matches. The cache also lives in a temp directory that does not survive the app restarting. Find another way: read the original photo's path, timestamp and size from the device library and use those to know the file has already been imported, so it is never copied to temp or hashed again.
        - *e* Limit how many import child tasks run at once: 2 on mobile, 10 on desktop.
        - *e* The progress indicator stops while photos are still being imported, and so does the progress logging: both are fed by the same message. Progress is only reported twice per batch, once before the batch starts and once after it finishes, so with a batch of 60 there is no update at all for ten minutes or more. Report progress per photo.
        - *e* The new database took too long to show in the Open database list. Fix by reading the databases into memory before the dialog is opened.
    - Low priority
        - *e* Automatic import must keep running at a low priority when the app is in the background, and when the screen is off. Right now nothing keeps it alive: there is no background service and no wake lock, so Android is free to freeze the work.
        - *e* Automatic import never says how many photos are left to import. Not knowing how much is still to come is no good, especially on a big library.
        - *e* Import the existing library newest first, not oldest first, so users see their recent photos quickly.
        - *e* Remove the lone file name shown under the counts on the automatic import card. It has no label and no explanation, and serves no good purpose.
        - *e* Split the Import page in two. One page for importing, where photos and videos are selected and added. A separate Import Log page that just shows what was recently imported. One page doing both jobs does not fit on a phone screen.
        - *e* The "My Photos" button in the Open database list is too small. Make it double the size and add padding underneath to separate it from the other buttons.
        - *e* The wording "a private photo database is created for you" needs updating. Check what it really does first.
        - *e* Better if turning the toggle on prompted to add a folder, after Allow is tapped.
- [ ] [auto-import-no-permission](mobile/auto-import/auto-import-no-permission.md)
- [ ] [auto-import-delete-after-backup](mobile/auto-import/auto-import-delete-after-backup.md)

### Import
- [ ] [import-photo-and-video](mobile/import/import-photo-and-video.md)

### Gallery
- [ ] [view-and-edit-asset](mobile/gallery/view-and-edit-asset.md)
- [ ] [export-asset](mobile/gallery/export-asset.md)

### Download
- [ ] [download-assets](mobile/download/download-assets.md)

### Database
- [ ] [create-and-open-database](mobile/database/create-and-open-database.md)
- [ ] [load-large-database](mobile/database/load-large-database.md)
- [ ] [view-database-details](mobile/database/view-database-details.md)
- [ ] [remove-recent-database](mobile/database/remove-recent-database.md)
- [ ] [open-encrypted-database](mobile/database/open-encrypted-database.md)
- [ ] [edit-database-origin](mobile/database/edit-database-origin.md)

### Sync
- [ ] [sync-with-another-database](mobile/sync/sync-with-another-database.md)

### Move
- [ ] [move-file-between-databases](mobile/move/move-file-between-databases.md)

### Replication
- [ ] [replicate-to-another-database](mobile/replication/replicate-to-another-database.md)
- [ ] [partial-replica-and-prefetch](mobile/replication/partial-replica-and-prefetch.md)

### S3
- [ ] [s3-database](mobile/s3/s3-database.md)

### Secrets
- [ ] [add-and-view-secret](mobile/secrets/add-and-view-secret.md)
- [ ] [add-encryption-key](mobile/secrets/add-encryption-key.md)
- [ ] [add-s3-credentials](mobile/secrets/add-s3-credentials.md)

### LAN Share
- [ ] [mobile-to-mobile](mobile/lan-share/mobile-to-mobile.md)
- [ ] [desktop-to-mobile](mobile/lan-share/desktop-to-mobile.md)
- [ ] [cli-to-mobile](mobile/lan-share/cli-to-mobile.md)

### News
- [ ] [news-notifications](mobile/news/news-notifications.md)
