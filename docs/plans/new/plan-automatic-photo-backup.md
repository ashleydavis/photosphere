# Automatic photo backup: default private repo, auto-import, and S3 backing

## Overview

Photosphere can already create databases, import files, sync bidirectionally, replicate partially, encrypt, and talk to S3, on desktop, CLI and mobile. What it cannot do is behave like a photo backup app: there is nothing that notices a photo the user just took, imports it on its own, and pushes it to a remote copy. This milestone adds that. The user turns on one setting, the app creates a private local database for them, watches the device's photo sources, imports what it finds (new arrivals immediately, the existing library backfilled slowly), shows the arrivals landing in the gallery, and, once the local database is connected to an S3 remote, keeps the remote up to date over Wi-Fi. Two optional behaviours follow from that: deleting the source file off the device once it is safely in the local database, and dropping local original files once they are confirmed on the remote so the local database can stay small as a partial replica. Nearly all of the heavy lifting is existing code (`import-assets`, `sync-database`, `replicate-database`, partial databases, the sync settings, the vault, the S3 storage layer). The genuinely new parts are: the scan/watch source abstraction and its native mobile implementation, the long-running auto-import task with its two priority lanes, retention policies for local originals, source-file cleanup, and consolidating a standalone local database into a pre-existing remote that has a different database id.

Order of work matters: the CLI `watch` command is built and tested first, because it exercises the whole engine (scan, import, sync, cleanup, retention) with the cheapest and fastest test harness in the repository. Desktop and mobile then reuse that engine.

## Issues

## Steps

Every step below is complete only when `bun run compile` succeeds, the unit tests named in that step exist and pass, and any smoke test named in that step passes. New or changed functions get unit tests. React components, contexts and hooks are not unit tested; they are covered by the smoke tests instead.

### Phase 1: the shared engine and the CLI watch command

1. Create `packages/api/src/lib/auto-import-settings.ts` defining the platform-neutral settings this feature reads: `IAutoImportSettings` (whether auto-import is enabled, the source list, whether source cleanup is enabled, the backfill pacing in items per minute, the new-arrival poll interval in milliseconds), `IAutoImportSource` (a discriminated union of a folder source with an absolute path and a recurse flag, and a device-album source with an album identifier), and `DEFAULT_AUTO_IMPORT_SETTINGS` with auto-import off, cleanup off, a backfill rate of 60 items per minute and a 30 second poll interval. Add a `normaliseAutoImportSettings` function that fills missing fields from the defaults and drops malformed sources, so a hand-edited or older settings blob cannot crash the task. Export from `packages/api/src/index.ts`.

2. Create `packages/node-utils/src/lib/photo-folders.ts` with `getDefaultPhotoFolders(): string[]`, returning the operating system's photo locations that exist on this machine: on Windows the user's `Pictures` folder and its `Camera Roll` subfolder, on macOS the user's `Pictures` folder, on Linux the XDG pictures directory falling back to `Pictures` under the home directory. It must return only folders that exist, and must never throw when a folder is missing. Export from `packages/node-utils/src/index.ts`.

3. Create `packages/node-api/src/lib/media-source.ts` defining the abstraction the auto-import task scans through: `IMediaItem` (a stable source identifier, the absolute or sandbox-relative path the importer can read, the display name, the content type, the size in bytes, and the creation timestamp), `IMediaSourceListPage` (the items in this page and an opaque cursor for the next page, undefined at the end), and `IMediaSource` with `listPage(cursor, pageSize)`, `watch(onChanged)` returning an unsubscribe function, `exportItem(item)` returning a readable local path for import, and `releaseItem(item)` for sources that materialise a temporary copy. Include `deleteItems(sourceIds)` for the cleanup behaviour, which throws a named error on a source that cannot delete.

4. Add `FolderMediaSource` to `packages/node-api/src/lib/media-source.ts` (or a sibling `folder-media-source.ts` if the file grows past a few hundred lines): it implements `IMediaSource` over a list of folders using the existing `scanPaths` in `packages/node-api/src/lib/file-scanner.ts` for enumeration, so the existing content-type filtering and zip handling are reused. `watch` uses `fs.watch` on each folder (recursive where the platform supports it) and additionally re-lists on the poll interval, because recursive watching is not dependable on Linux and the poll is what actually guarantees nothing is missed. `exportItem` returns the file path unchanged, `releaseItem` does nothing, and `deleteItems` unlinks the files.

5. Create `packages/node-api/src/lib/auto-import-queue.ts` holding the pacing logic as plain, testable functions with no I/O: an `AutoImportQueue` class with two lanes, a fast lane for items the watcher reported since the task started and a paced lane for the backfill, a `nextBatch(now)` method that returns fast-lane items immediately and releases backfill items only when the configured items-per-minute budget allows, and a persisted `IBackfillCursor` so a restart resumes where it stopped rather than rescanning from the beginning. Nothing in this file touches the filesystem or the queue; it decides only what should be imported next.

6. Create `packages/node-api/src/lib/auto-import.worker.ts` with `IAutoImportData` (the target database path and descriptor, the settings from step 1, the session id) and `autoImportHandler`. It builds the media source, subscribes to changes, walks the source with `AutoImportQueue`, and for each released batch queues the existing `"import-assets"` task with the exported paths so all deduplication by content hash, write-lock batching and derivative generation are reused unchanged. It streams `auto-import-progress` messages (items seen, imported, skipped as duplicates, failed, backfill remaining, the current item name) and an `auto-import-item` message per imported asset so the UI can show arrivals one at a time. It checks `context.isCancelled()` in every loop, runs until cancelled, and persists the backfill cursor to the database's state so progress survives a restart. Register `"auto-import"` in `packages/node-api/src/lib/task-handlers.ts`.

7. Create `packages/node-api/src/lib/source-cleanup.ts` with `selectConfirmedForCleanup(importedItems, databaseHashes)`, a plain function returning the source ids whose content hash is confirmed present in the local database, and `runSourceCleanup(source, sourceIds, batchSize)` which calls `IMediaSource.deleteItems` in batches. Wire it into `autoImportHandler` behind the cleanup setting, running only after the import batch has committed. Deletion happens on confirmed presence in the *local* database, with no dependency on the remote.

8. Create `packages/api/src/lib/retention-policy.ts` with `IEvictionCandidate` (asset id, original size in bytes, imported timestamp, last viewed timestamp if known, and whether the file is confirmed present on the origin), `IRetentionContext` (total local original bytes, device free bytes, the current time), and `IRetentionPolicy` with a single `selectForEviction(candidates, context): string[]` method. Implement all four policies fully, each exported and each unit tested: `SizeBudgetRetentionPolicy` (keep local originals under a byte cap, oldest confirmed first), `RecentDaysRetentionPolicy` (evict confirmed originals older than N days), `FreeSpaceRetentionPolicy` (evict oldest confirmed until free space is above a threshold), and `DropWhenConfirmedRetentionPolicy` (evict every confirmed original). At the bottom of the file export a single `ACTIVE_RETENTION_POLICY` constant assigned to `SizeBudgetRetentionPolicy` with a 2 GB cap, with the other three assignments written out directly beneath it and commented out, so switching policy is uncommenting one line. Every policy must refuse to evict a candidate that is not confirmed on the origin.

9. Create `packages/node-api/src/lib/evict-originals.worker.ts` with `evictOriginalsHandler`: for a database that has an origin, load the origin's merkle tree, build `IEvictionCandidate` values for every local original by comparing local files against the origin's recorded hashes, apply `ACTIVE_RETENTION_POLICY`, and delete the selected local `original` and `display` files while leaving `thumb` and `micro` in place so the gallery stays browsable. It must never evict a file the origin does not hold with a matching hash. Register `"evict-originals"` in `packages/node-api/src/lib/task-handlers.ts`.

10. Create `apps/cli/src/cmd/watch.ts` with `IWatchCommandOptions` (extending `IBaseCommandOptions`, adding the source folders, a `--once` flag, a `--no-sync` flag, a `--cleanup` flag and a `--evict` flag) and `watchCommand`. It resolves the database the same way the other commands do via `loadDatabase` in `apps/cli/src/lib/init-cmd.ts`, defaults the folders to `getDefaultPhotoFolders()` when none are given, queues the `"auto-import"` task, prints progress from the task messages, queues `"sync-database"` after each import batch settles when an origin is configured, queues `"evict-originals"` after each successful sync, and runs until interrupted. With `--once` it performs a single pass and exits with a non-zero code if any item failed to import.

11. Register the watch command in `apps/cli/index.ts` next to the existing `set-origin` registration, with its description, arguments and the shared `dbOption`, `keyOption`, `verboseOption`, `yesOption` and `cwdOption`, and add an entry to `apps/cli/src/examples.ts`.

12. Add the CLI smoke tests listed under "Smoke Tests" for watch, cleanup and retention as new numbered directories under `apps/cli/smoke-tests/`, following the existing `test.sh` idiom (`source ../lib/common.sh`, `get_test_dir`, `invoke_command`, `check_exists`). Use the per-test temp directory allocator and never a fixed path or port.

### Phase 2: consolidation and connecting to a remote

13. Create `packages/node-api/src/lib/consolidate.ts` with `planConsolidation(localTree, remoteTree)`, a plain function returning which local assets are absent from the remote by content hash and which are already present, and `consolidateDatabases(...)` which pushes the absent assets and their metadata into the remote, skipping content the remote already holds, then re-stamps the local database as a partial replica of the remote by adopting the remote's database id, setting the remote as the origin in `.db/config.json`, and setting the partial flag in the local merkle tree's database metadata. It must leave `sync.ts`'s refusal to sync unrelated databases untouched: consolidation is a separate, explicit operation, and once it has run the two databases are related so ordinary sync applies.

14. Create `packages/node-api/src/lib/consolidate-database.worker.ts` wrapping step 13 as the `"consolidate-database"` task with progress messages, and register it in `packages/node-api/src/lib/task-handlers.ts`.

15. Create `apps/cli/src/cmd/connect.ts` with `connectCommand`: given a local database and a remote path (S3 or filesystem) plus the S3 credential secret name and encryption key secret name, it creates the remote database when nothing is there, runs `consolidateDatabases` when a database with a different id is there, and sets the origin when the remote is already related. Register it in `apps/cli/index.ts`. This is also the surface the CLI smoke tests use to prove consolidation, and it is the same code path the desktop and mobile connect actions queue.

16. Add the consolidation and multi-device CLI smoke tests listed under "Smoke Tests".

### Phase 3: desktop app

17. Create `packages/user-interface/src/lib/auto-import-config.ts` with plain functions over the generic `IConfig` from `packages/user-interface/src/context/config-context.tsx`: the config key constants (`autoImportEnabled`, `defaultDatabasePath`, `autoImportSources`, `autoImportCleanupEnabled`), `loadAutoImportSettings(config)`, `saveAutoImportSettings(config, settings)`, `getDefaultDatabasePath(config)` and `setDefaultDatabasePath(config, path)`. These are plain functions so they are unit tested; the React parts that call them are not.

18. Add `defaultDatabase` handling to the databases list: extend `IDatabaseEntry` in `packages/user-interface/src/context/platform-context.tsx` with an `isDefault` field, and add a `setDefaultDatabase(path)` platform method implemented on desktop by writing the `defaultDatabasePath` config value. Exactly one entry may hold it: setting a new default clears the previous one. Put the "only one default" rule in a plain function in `packages/user-interface/src/lib/auto-import-config.ts` and unit test it.

19. Add a "Create my private photo database" action that runs when auto-import is switched on and no default database exists: it queues the existing `"create-database"` task at the operating system application data directory under a fixed `photosphere-default` folder name with the display name "My Photos", adds it to the databases list, and marks it as the default. On desktop the path comes from the Electron `app.getPath("userData")` value passed through the existing platform layer; the shared UI never computes a platform path itself.

20. Add the "Automatic import" card to `packages/user-interface/src/pages/configuration.tsx`: the auto-import toggle, the editable source list (prefilled with the operating system photo folders on desktop, with add and remove), and the "delete originals after import" toggle, off by default with a short line saying what it does. Keep the existing card layout and the mobile sizing already used on that page.

21. Add the default badge and the two new actions to `packages/user-interface/src/pages/databases/databases-page.tsx`: "Set as default" in the per-entry action list built by `databaseActions`, and "Connect to remote", which opens a dialog reusing the S3 path and secret selection already present in `packages/user-interface/src/components/replicate-database-dialog.tsx` and queues `"consolidate-database"`. Add the same "Connect to remote" section to `packages/user-interface/src/pages/database-summary.tsx`, as requested, so both surfaces exist and one can be dropped later.

22. Add the auto-import progress panel to `packages/user-interface/src/pages/import/import-page.tsx`, shown only while the default database is the open database: counts of imported, skipped and failed, the backfill remaining, the current item, and a pause/resume control that cancels or requeues the `"auto-import"` task by its source tag. It subscribes to `auto-import-progress` and `auto-import-item` messages through the existing task message subscription used by `ImportContextProvider`.

23. Make arriving assets visible in the gallery as they land: on each `auto-import-item` message, add the asset through the same path `packages/user-interface/src/context/asset-database-source.tsx` already uses when a manual import completes, and give a newly added gallery item a short fade and scale-in transition in `packages/user-interface/src/pages/gallery/` so the user can see something is happening. No new state store: the arrival path is the existing one.

24. Wire the desktop app to run the engine: in `apps/desktop/src/main.ts` (and the worker wiring in `apps/desktop/src/lib/worker-pool-electron-main.ts`), start the `"auto-import"` task for the default database when the setting is on and stop it when the setting goes off or the app quits, and queue `"evict-originals"` after each successful sync of the default database. Reuse the existing sync scheduling and the existing Wi-Fi and sync-enabled settings in `packages/user-interface/src/context/sync-context.tsx` and `packages/user-interface/src/lib/sync-gate.ts`; add no new network settings.

25. Add the Electron smoke tests listed under "Smoke Tests" as new numbered directories under `apps/desktop/smoke-tests/`.

### Phase 4: mobile apps

26. Add the Android media library layer: create `apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/MediaLibrary.java` querying `MediaStore` images and videos with paging (id, display name, mime type, size, date taken, bucket name), exporting a chosen item into the sandbox import temp directory used by the existing picker path, listing albums for the exclusion list, and deleting a batch through `MediaStore.createDeleteRequest` so a single system dialog covers the batch. Register a `ContentObserver` that pushes change events into the engine through a `globalThis.__mediaLibraryEvent` entry point, following the inbound event pattern `TcpHost` already uses. Add the host functions to `HostFunctions.java` and `HostBridge.java`, and the media permissions to the manifest with the runtime request exposed as new `JsEnginePlugin` methods.

27. Add the iOS media library layer: create `apps/ios-frontend/ios/App/App/JsEngine/MediaLibrary.swift` using the Photos framework for the same operations (paged `PHAsset` fetch, resource export into the sandbox import temp directory, album listing, batch deletion through `PHPhotoLibrary.performChanges`), a `PHPhotoLibraryChangeObserver` pushing into the same `__mediaLibraryEvent` entry point, and the matching registrations in `HostFunctions.swift` and `HostBridge.swift`. Add `NSPhotoLibraryUsageDescription` to the app's `Info.plist`. Everything must build under Xcode 14.2 on macOS 12.7.6; use availability checks rather than raising any minimum version.

28. Create `packages/mobile-worker/src/shims/media-library.ts` exposing typed wrappers over the new host functions, following the existing shim style, and add `DeviceMediaSource` implementing `IMediaSource` from step 3 on top of it, so `auto-import.worker.ts` runs unchanged on mobile. Confirm the worker bundle builds and that the parity test in `apps/ios-frontend/ios/App/AppTests/WorkerBundleParityTests.swift` still passes.

29. Add the mobile permission handling in `packages/mobile-frontend/src/lib/` (a new `mobile-media-permission.ts` with plain, unit-testable functions plus its wiring in `platform-provider-mobile.tsx`): switching auto-import on requests the photo permission, and on denial the setting is written back to off and a message explains that permission is needed and where to grant it. The default database on mobile is created in the app sandbox with the same fixed name as desktop.

30. Add the batched device cleanup on mobile: accumulate confirmed-imported source ids and issue one delete request per batch through the new host function, surfacing the count in the Import page panel. The batch size is a named constant, not a magic number.

31. Stage the delete confirmation instead of automating the system dialog, following the injection points the app already keeps for native interactions a test cannot reach (`setInjectedPickedFiles`, `setInjectedPickFolderResult`, `setInjectedExportOutcome`). Add `setInjectedDeleteOutcome(outcome: "deleted" | "cancelled")` beside the cleanup code in `packages/mobile-frontend/src/lib/`, consumed once and undefined in production so the real request is issued, plus its window event in `packages/user-interface/src/lib/test-driver.ts` and its command in `apps/smoke-tests/lib/control-bridge.ts`, mirroring `TEST_STAGE_EXPORT_EVENT`. The staged outcome is passed through to the native layer so its completion handler runs for real without presenting the dialog, exactly as the export injection does. Everything above the dialog stays real code under test: selecting confirmed items, batching, the setting, and handling both answers. The native delete itself is covered by the Android and iOS unit tests in step 26 and step 27, and a real file really being deleted is proved by the CLI and Electron tests.

32. Add the mobile smoke tests listed under "Smoke Tests" as new numbered directories under `apps/smoke-tests/tests/`. Media is placed on the device from outside the app: `adb push` into the emulator's camera directory followed by a MediaStore scan on Android, and `xcrun simctl addmedia` on iOS. Permissions are granted from outside too, with `adb shell pm grant` and `xcrun simctl privacy grant photos`. No test-only code is added to the app for any of this.

33. Update the documentation: add an "Automatic import" section to `docs/development.md` and a new `docs/automatic-photo-backup.md` describing the sources, the two import lanes, the retention policies and how to switch the active one, consolidation, and what each platform can and cannot do. Add the new test scripts and their watched paths to `what-changed.yaml` so `bun run test:everything` runs them when the relevant code changes, and add the new CLI command to the README's command list.

## Unit Tests

- `packages/api/src/test/lib/auto-import-settings.test.ts`: `normaliseAutoImportSettings` fills missing fields, drops malformed sources, and leaves valid settings untouched.
- `packages/node-utils/src/test/lib/photo-folders.test.ts`: `getDefaultPhotoFolders` returns only folders that exist, per platform branch, and returns an empty list rather than throwing when none exist.
- `packages/node-api/src/test/lib/media-source.test.ts`: `FolderMediaSource` lists and pages items, filters by content type, exports and releases items, reports watcher changes, and deletes files through `deleteItems`.
- `packages/node-api/src/test/lib/auto-import-queue.test.ts`: fast-lane items are released ahead of backfill items, the backfill respects the items-per-minute budget, the cursor resumes mid-library, and an item already imported is not queued twice.
- `packages/node-api/src/test/lib/auto-import.worker.test.ts`: the handler queues `import-assets` for released batches, emits progress and item messages, stops on cancellation, persists and resumes its cursor, and continues after one item fails to import.
- `packages/node-api/src/test/lib/source-cleanup.test.ts`: `selectConfirmedForCleanup` selects only hashes confirmed in the local database, and `runSourceCleanup` batches deletions and surfaces a source that refuses to delete.
- `packages/api/src/test/lib/retention-policy.test.ts`: one test per policy covering selection order and boundaries, plus a shared test that no policy ever selects a candidate that is not confirmed on the origin.
- `packages/node-api/src/test/lib/evict-originals.worker.test.ts`: evicts only confirmed originals, leaves thumbnails and micro thumbnails in place, and evicts nothing when there is no origin.
- `packages/node-api/src/test/lib/consolidate.test.ts`: `planConsolidation` separates assets absent from the remote from those already present by content hash, and `consolidateDatabases` pushes only the absent ones, adopts the remote id, sets the origin, and sets the partial flag.
- `packages/user-interface/src/test/lib/auto-import-config.test.ts`: settings load and save round-trip through a fake `IConfig`, missing values fall back to the defaults, and setting a new default database clears the previous one.
- `packages/mobile-frontend/src/test/mobile-media-permission.test.ts`: a granted permission leaves the setting on, a denied permission writes the setting back to off and produces the explanation.
- `packages/mobile-worker/src/test/shims/media-library.test.ts`: the shim passes through to the host functions and surfaces a host error rather than swallowing it.
- Android unit tests under `apps/android-frontend/android/app/src/test/java/au/com/codecapers/photosphere/jsengine/MediaLibraryTest.java`: paging over a stub content resolver, album listing, export path construction, and building a batch delete request.
- iOS unit tests in a new `apps/ios-frontend/ios/App/AppTests/MediaLibraryTests.swift`: the same coverage against stubbed Photos results.

## Smoke Tests

CLI (`apps/cli/smoke-tests/`, run by `bun run test:cli`):

- `psi watch --once` imports a new file dropped in a watched folder and reports it.
- `psi watch` running continuously picks up a file created after it started, within the poll interval.
- A file already in the database is skipped as a duplicate rather than imported twice.
- `--cleanup` deletes the source file after the asset is confirmed in the local database, and leaves it alone when the import fails.
- `psi watch` with an origin configured syncs imported assets to the origin, then `evict-originals` drops confirmed local originals while thumbnails remain and the asset still opens from the origin.
- `psi connect` creates the remote when it does not exist, and consolidates into a pre-existing unrelated remote: local-only assets appear on the remote, content already on the remote is not duplicated, and afterwards ordinary `psi sync` succeeds where it previously refused.
- Two local databases watching separate folders, both connected to one remote, each end up with the other's assets after sync, proving the multi-device case.

Electron (`apps/desktop/smoke-tests/`, run by `bun run test:electron`):

- Switching auto-import on with no default database creates one, marks it as the default in Manage Databases, and shows it in the databases list.
- A file appearing in a watched folder is imported and shows up in the gallery without reopening the database, with the Import page panel reporting it.
- Only one database can be the default: setting a second clears the first.
- Connect to remote against the local MinIO S3 server used by the existing S3 tests, then an auto-imported asset reaches the remote.
- Consolidating into a pre-existing unrelated remote through the Manage Databases action, and the same action from the database summary page.
- The cleanup toggle deletes the watched-folder source file after import.

Mobile (`apps/smoke-tests/tests/`, run by `bun run test:and` and `bun run test:ios`):

- Auto-import switched on with photo permission granted creates the default database and imports an image placed in the device photo library from outside the app.
- A photo added to the library while the app is running is imported and appears in the gallery.
- Denying the photo permission switches the setting back off and shows the explanation.
- Auto-import into the default database syncs to a MinIO S3 remote, following the existing S3 mobile tests.
- The excluded-album setting keeps an image in that album out of the database.
- Device cleanup asks to delete exactly the source ids that were confirmed into the database, in one batched request, with the confirmation staged by step 31. A staged "cancelled" leaves the app's records intact and does not retry in a loop, and with the cleanup setting off no delete is ever requested.

## Verify

- `bun run compile` succeeds.
- `bun run test` passes, including every unit test listed above.
- `bun run test:cli` passes, including the new watch, cleanup, retention, consolidation and multi-device tests.
- `bun run test:electron` passes, including the new desktop tests.
- `bun run test:and` passes on the Android emulator, including the new mobile tests. Check the pool with `bun run emu:and:pool:status` at the moment it is needed rather than assuming its state.
- `bun run test:ios` passes on the macOS machine.
- `bun run test:everything -- --force` passes.
- `bun run test:parallel` reports no suite that fails when run beside another copy of itself or beside another suite.

## Notes

- Reuse over new code is the rule throughout. Import goes through the existing `"import-assets"` task, so content-hash deduplication, the write lock, derivative generation and the hash cache are inherited rather than rebuilt. Sync and its Wi-Fi and enabled settings are the existing ones in `packages/user-interface/src/context/sync-context.tsx` and `packages/user-interface/src/lib/sync-gate.ts`, unchanged. Partial databases, the origin config, and replication already exist.
- Raw originals are stored exactly as they come off the device. The transcoded copy is the existing `display` asset (MP4 for video, JPEG for images), and the existing import path already produces it, so no new conversion work is in this plan.
- The local default database is created as an ordinary full database, because a partial database with no origin has nowhere to fetch from. It becomes a partial replica at the moment it is consolidated with a remote, which is when eviction starts applying. This matches the intent that the local copy is a partial one, and it avoids inventing a second meaning for the partial flag.
- The active retention policy was not chosen, so this plan makes it `SizeBudgetRetentionPolicy` with a 2 GB cap and leaves the other three implemented, exported, unit tested and commented out at the selection point, so switching is uncommenting one line. Change the constant in `packages/api/src/lib/retention-policy.ts` to try another.
- Source deletion happens on confirmed presence in the local database, with no dependency on the remote, as requested. That means a user with cleanup on and no remote connected is trusting one local copy, so the setting is off by default and its description says what it does.
- Mobile deletion cannot be silent: Android 11 and later force a system confirmation for media the app does not own, and iOS confirms deletion of assets the app did not create. That is why deletion is batched into one request rather than one per photo.
- The mobile delete confirmation is staged rather than tapped by UI automation (step 31). This is deliberate and it has a limit worth stating plainly: the mobile smoke tests prove the app asked to delete the right things and handled the answer, not that the native delete removes the file. The native delete is covered by Android and iOS unit tests, and an original really being deleted is proved end to end by the CLI and Electron tests, where no dialog exists. If that split is ever judged too weak, the alternative is `uiautomator` plus `adb shell input` on Android and XCUITest on iOS, which depends on OS dialog wording and control ids and breaks between versions.
- Placing media on a test device is done entirely from outside the app (`adb push` plus a MediaStore scan, `xcrun simctl addmedia`, `adb shell pm grant`, `xcrun simctl privacy grant photos`). No test-only scaffolding is added to the app.
- Sync keeps refusing to work between unrelated databases. Consolidation is a separate, explicit operation that makes them related, after which sync behaves normally. Nothing in this plan weakens that refusal.
- Background operation is out of scope: the scan, import and sync run while the app is in the foreground. The auto-import task is a long-running task like `asset-server`, so an Android foreground service or an iOS background task can drive the same task later without changing the engine.
- The exact command for making a pushed file visible to Android's MediaStore differs by API level, so step 32 must confirm which of the available approaches works on the emulator image the pool uses before the test is accepted, rather than assuming one.
