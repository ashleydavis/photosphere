# Reset device: clear the app's storage, its databases and its secrets

## Overview

There is no way for a user to clear the app's own state. Until recently the smoke tests had one (the `reset-config` test command), but that was scaffolding shipped in the app purely for tests and has been removed. A user who wants to hand a phone on, start again, or clear credentials off a device has no equivalent. This plan adds a real one: a "Reset device" action in Settings that closes the open database, removes every configured database entry and the recent list, deletes every stored secret, and clears the app's own storage, behind two confirmations because it cannot be undone.

Clearing the app's own storage is what removes the databases from a phone. On mobile a local database path is a name inside the app's storage sandbox (`pickMobileFolder` returns a sandbox-relative name), so every local database on a phone is inside the app's storage and goes with it. On desktop the app's storage is the config directory and the cache directory, which hold only the app's own files, so a database at a path the user chose is removed from the list but its files are left exactly where they are.

## What reset must never touch

This is the part of the feature that can hurt somebody, so it is stated before the steps and the implementation must make it true by construction, not by care:

- **Never a file outside the app's own storage.** The task deletes the contents of `getConfigDir()` and `getCacheDir()` and nothing else. It takes no path from its caller, so no config entry, no database path and no future caller can point it at a user's photos. On desktop a database in Documents or on an external drive is forgotten, never deleted.
- **Never anything in S3 or on another machine.** Nothing in this feature opens remote storage. A configured S3 database is removed from the device's list; its bucket is untouched.
- **Never the device photo library.** Nothing here goes near the media store or the camera roll.

On mobile the boundary is enforced twice over: the worker's `fsRm` resolves every path inside the app's storage sandbox and refuses to leave it, so even a bug in the task cannot reach outside the app.

## Issues

## Steps

1. **Add the `reset-app-storage` worker task.** Create `packages/node-api/src/lib/reset-app-storage.worker.ts` exporting `resetAppStorageHandler`. It takes no input naming a path. It reads `getConfigDir()` and `getCacheDir()` from `node-utils`, deduplicates them (on a device both answer the storage sandbox root, so the same directory must not be emptied twice), and for each one lists its entries and removes each with a recursive, forced delete, leaving the directory itself in place. Missing directories are not an error. It returns a named result interface naming the directories it emptied and how many entries went in total. Register it in `initTaskHandlers` (desktop, CLI and dev-server) and in `packages/mobile-worker/mobile-worker-entry.ts` (mobile), the way `check-database-exists` is registered on both. Must compile and have unit tests passing before this step is complete.

2. **Add the reset logic as a plain function.** Create `packages/user-interface/src/lib/reset-device.ts` exporting `resetDevice`, taking the operations it needs via a named options interface rather than the whole platform context, so it is unit-testable without React: `closeDatabase`, `getDatabases`, `removeDatabaseEntry`, `listSecrets`, `deleteSecret`, `resetAppStorage`, and a small key/value store for the interface's own settings. In order: close the open database (its files may be about to go), remove every database entry, delete every secret, clear the interface's own local storage (the theme, the gallery layout, this client's id, the news already shown: every key there belongs to this app), then run the storage reset. Returns a named result interface reporting how many databases, secrets, settings keys and storage entries were removed. Every failure is thrown, not swallowed: a reset that only half happened must say so.

3. **Add the task runner the reset calls.** Create `packages/user-interface/src/lib/reset-app-storage-task.ts` exporting `runResetAppStorageTask`, which queues `reset-app-storage` on a `TaskQueue` at `TaskPriority.Interactive`, awaits it and returns what it removed, throwing when the task fails (the pattern `runConfigTask` in `mobile-databases-config-file.ts` already uses). It passes no path, because the handler has none to take. No new platform-context method is needed: the four platform operations the reset uses already exist on `IPlatformContext`, and the storage reset goes through the shared task queue, which both platforms already run.

4. **Add the confirmation dialog.** Create `packages/user-interface/src/components/reset-device-dialog.tsx` following the shape of `remove-database-dialog.tsx`. Two steps in the one dialog: the first states exactly what will be removed (the counts of databases and secrets, read from the app context) and names the two losses a user would not otherwise expect, because both are unrecoverable: the photos inside the app's own databases go with them, and the encryption keys go with the secrets, without which an encrypted database cannot be opened again; the second is a distinct final confirmation whose confirm button is the only way through. Cancel and backdrop dismiss at either step return to nothing having happened. It builds the options for `resetDevice` from the platform context, the database context (`closeDatabase`) and the task runner, refreshes the app context's lists, and logs a line saying what was removed once the lists have been re-read. A failure raises a toast that does not auto-dismiss, because a half-finished reset must not look like a finished one. Give every control a `data-id` so the smoke tests can drive it. Not unit tested (a React component); covered by the smoke tests below. Add a story for it beside the other dialogs.

5. **Add the entry point to Settings.** In `packages/user-interface/src/components/configuration-dialog.tsx`, add a section at the end with a danger-styled button that opens the dialog, below the theme, photo-size, syncing and automatic-import settings, so it is not the first thing a thumb lands on. This is the settings UI both platforms actually open, from `main.tsx`; `pages/configuration.tsx` looks like the settings screen but nothing in the app renders it (only its story does), so putting the entry point there would leave it unreachable.

6. **Add the two harness helpers the mobile test needs.** Add `android_sandbox_path_exists` to `apps/smoke-tests/lib/android.sh` and `ios_sandbox_path_exists` to `apps/smoke-tests/lib/ios.sh`, beside the existing `wait_for_file` helpers, so a test can assert a database directory in the app's storage is gone rather than waiting for one to appear. Add `wait_for_value_gone` to `apps/smoke-tests/lib/common.sh`, mirroring the desktop suite's, for watching a row leave the screen. Harness shell, so no tests of their own (see the shell rules in CLAUDE.md); they are proven by the test that uses them.

7. **Add the smoke tests.** Add `apps/smoke-tests/tests/52-reset-device/test.sh` (mobile) and `apps/desktop/smoke-tests/37-reset-device/`, `38-reset-device-s3/` and `39-reset-device-failure/` (desktop), following the neighbouring tests and taking the next free numbers in each suite.

## Unit Tests

- `packages/node-api/src/test/lib/reset-app-storage.worker.test.ts` covering `resetAppStorageHandler`, with `PHOTOSPHERE_CONFIG_DIR` and `PHOTOSPHERE_CACHE_DIR` pointed at directories under the test's own temp directory: empties both directories including nested trees, leaves the directories themselves in place, leaves a sibling directory outside both untouched, removes each entry once and reports the right counts when both variables name the same directory (the device case), and succeeds when a directory does not exist.
- `packages/user-interface/src/test/lib/reset-device.test.ts` covering `resetDevice`: closes the database before anything is deleted, removes every database entry, deletes every secret, clears the stored settings, runs the storage reset last, reports the counts, is a no-op that still succeeds when there is nothing to remove, and propagates a failure from any step rather than reporting success.
- `packages/user-interface/src/test/lib/reset-app-storage-task.test.ts` covering `runResetAppStorageTask` against a recording queue backend: queues the task as interactive with no path in its data, reports the entries the task removed, reports none when the task says nothing, and throws when the task fails.
- No unit tests for the dialog or the settings UI: React components, covered by the smoke tests.

## Smoke Tests

- Mobile `52-reset-device`: with a database created in the app's storage and a secret added through the real Add Secret UI, cancelling at the first step leaves both in place; cancelling at the second step also leaves both in place; confirming both steps empties the database list and the secrets list, and the database directory and databases.toml are gone from the app's storage sandbox.
- Desktop `37-reset-device`: the same three cases, with a photo imported first so the database has something to lose and the app has written a real hash cache and import record. Asserts the config and cache directories are emptied, and the assertion that matters most on desktop: the database directory on disk, which lives outside both, still exists after the reset and still holds the imported photo.
- Desktop `38-reset-device-s3`: a real database in a real bucket (the local MinIO), with a photo imported into it, is removed from the list and its credentials deleted, and the bucket still holds the database and the photo afterwards. The bucket is read back with the CLI, through a vault of its own so the reset cannot take the credentials the check depends on, and it is read **before** the reset as well as after: a check that cannot tell "the reset destroyed it" from "this check never worked" proves nothing.
- Desktop `39-reset-device-failure`: a reset that cannot finish says so and stops. The vault file is replaced from outside the app with something that does not parse, which is what a truncated write leaves; the reset then fails at the secrets step. Asserts the toast is on screen, the failure is in the log, no completion is reported, and the app's own storage is untouched, so a reset that broke half way never looks like one that finished.

## Verify

- `bun run compile` completes with no errors.
- `bun run test` passes for every package.
- `bun run test:everything` passes (compile, unit, CLI, Electron and the mobile suites).

## Notes

- The scope decision, and the reason for it: a local database may be the only copy of somebody's photos, and on desktop the user chose where it lives. So the reset clears what the app owns, which on a phone is everything including the databases, and on a desktop is the app's settings and caches. The dialog says this plainly, or a user will assume more went than did, or less.
- The task deliberately takes no path argument. A task that accepted "delete this directory" would be one bad caller away from deleting a photo library, and nothing in the type system would catch it.
- Removing entries one at a time before the wipe means one config write per entry rather than one write for the whole reset. That is the existing behaviour of removing a database entry, it lets each platform do its own bookkeeping (the desktop menu and the databases-changed event), and the wipe that follows removes the file those writes went to anyway.
- The iOS half of step 6 cannot be exercised here: that suite needs macOS and Xcode, and this machine is Linux. It is written to match the Android helper and must be reported as unverified.
