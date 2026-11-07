# Register a replication's destination in the database list, on every platform

## Overview

A replication makes a database and then, on two platforms out of three, tells nobody. The desktop registers the destination in `databases.toml` from its main process (`handleReplicateSucceeded` in `apps/desktop/src/main.ts`), so a replica made there appears on the Manage Databases page. The CLI's `psi replicate` does not, and mobile does not, so a replica made on a phone exists on disk and is invisible in the app: the user has to add it by hand, guessing the path they typed, and the replicate dialog meanwhile tells them "Replication completed. The replica has been added to your databases at ...", which is not true on the platform they are most likely to be standing in front of. This was hit setting a phone up against an existing bucket database: the replication finished in seconds, the Manage Databases page was unchanged, and there was no way to tell success from failure. The fix is to move the registration into the shared `replicate-database` task, where every caller reaches it, and delete the desktop's private copy, following what `create-default-database.worker.ts` already does for the database automatic import makes.

## Issues

## Steps

1. **Write the pure part first.** Add a module `packages/node-api/src/lib/replica-registration.ts` exporting a function that decides what to add, given the existing entries and the replication's inputs, and returns either the new entry or nothing when one with that path is already listed. It must: match an existing entry by exact path (never by name), derive the entry name from the destination path's last segment, make that name unique against the existing entries when it is taken (the worker writes the whole file rather than going through `addDatabaseEntry`, so nothing else would catch a duplicate), and carry `origin` from the source path and `s3Key`/`encryptionKey` from the destination's secret names, because without those the replica cannot be opened again. Unit tests for every case. `bun run compile` and `bun run test` pass before this step is finished.

2. **Register from the task.** Add a `databasesConfigPath` field to `IReplicateDatabaseData` (the type lives in `packages/api`), and at the end of `replicateDatabaseHandler` in `packages/node-api/src/lib/replicate-database.worker.ts`, after the encryption marker is written, read the list with `readDatabasesConfigHandler`, call the step 1 function, and when it returns an entry write the list back with `writeDatabasesConfigHandler`, carrying `recentDatabaseNames` and `lastDatabase` through unchanged. This is exactly the shape `createDefaultDatabaseHandler` uses, including the reason the path is an input: the file is at the root of the storage sandbox on a phone and in the config directory on the desktop. Registration failing must fail the task loudly rather than being swallowed, because a replica that is not listed is the bug being fixed. Unit test the handler's new behaviour with the config handlers mocked, as `consolidate-database.worker.test.ts` mocks its prefetch. Compile and tests pass.

3. **Pass the path from every caller.**
    - `packages/node-api/src/lib/replicate-database.ts` (`replicateDatabase`): accept the path and put it in the task data it builds.
    - `apps/cli/src/cmd/replicate.ts`: pass `getDatabasesConfigPath()` from `packages/node-api/src/lib/databases-config.ts`.
    - `packages/user-interface/src/components/replicate-database-dialog.tsx`: the shared dialog cannot know where the file is, so add a `databasesConfigPath` accessor to `IPlatform` in `packages/user-interface/src/context/platform-context.tsx`, implemented as the config-directory path in `apps/desktop-frontend/src/lib/platform-provider-electron.tsx` and as `databases.toml` in `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx`, which is the literal the mobile auto-import planner already passes for the same file.
    Compile passes; unit tests for the changed wrapper.

4. **Delete the desktop's private copy.** Remove the entry-writing half of `handleReplicateSucceeded` in `apps/desktop/src/main.ts` so there is one implementation. Keep the success notification, and keep the `databases-changed` message to the renderer only if step 5 does not already cover the refresh; if it does, remove it and say so in the commit.

5. **Refresh the list on every platform.** `packages/user-interface/src/context/app-context.tsx` already refreshes when a task the interface did not start changes the list: its `onTaskComplete` effect matches `result.type === "create-default-database"`. Extend that to match `replicate-database` as well. This is the route that works everywhere, which matters because `onDatabasesChanged` is implemented on the desktop and is an empty function on mobile (`platform-provider-mobile.tsx`), so a mobile refresh must not depend on it.

6. **Deal with the empty subscription.** `onDatabasesChanged` in `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx` returns an unsubscribe function and never calls its callback, which is a subscription that reports success and does nothing. Either implement it on mobile or remove it from `IPlatform` and from the desktop provider now that step 5 covers the case it existed for. Whichever is chosen, no platform is left with a no-op implementation of it.

7. **Make a background failure visible.** Pressing **Run in background** in the replicate dialog calls `onClose`, so the `catch` in `handleStart` sets error state on an unmounted dialog and the only record is `log.exception`. Report the failure through the same notification route the desktop already uses for the success case, so a replication that fails after its dialog is closed says so. Covered by the smoke test below rather than a unit test, since the dialog is a React component.

8. **Update the documentation to match the code**, including the name the registration actually gives the entry and what the app shows when a background replication fails. The documents affected are `docs/android-onboarding.md`, whose replication section tells the reader to add the entry by hand, and the `replicate` section of `Command-Reference.md` plus `Managing-Databases.md` in the wiki working directory.

## Unit Tests

- `packages/node-api/src/test/lib/replica-registration.test.ts`: returns nothing when an entry with the destination path is already listed; returns an entry named after the destination's last segment; makes the name unique when that name is taken by another entry; carries the origin, the S3 key and the encryption key; matches by path and not by name (an entry with the same name at a different path does not count as already registered).
- `packages/node-api/src/test/lib/replicate-database.worker.test.ts`: the handler writes the list when the destination is new, does not write it when the destination is already listed, carries `recentDatabaseNames` and `lastDatabase` through untouched, and fails the task when the write fails.
- `packages/node-api/src/test/lib/replicate-database.test.ts`: the `replicateDatabase` wrapper puts `databasesConfigPath` in the task data it builds.
- No unit tests for the replicate dialog, the platform providers or `app-context`: React components, contexts and hooks are covered end to end.

## Smoke Tests

- `apps/cli/smoke-tests/17-replicate`: after `psi replicate`, `psi dbs list` shows the destination, with its path, and running the same replication again does not add a second entry.
- `apps/smoke-tests/tests/17-replicate-database`: after the replication completes, the destination appears on the Manage Databases page without the page being reopened, and its **View details** shows the source as its **Origin**.
- `apps/smoke-tests/tests/17-replicate-database`: a replication whose destination is already registered leaves the list with one entry for it, not two.
- A replication into an S3 destination with an encryption key registers the entry carrying both secret names, so the replica opens again afterwards. `apps/smoke-tests/tests/41-s3-database-lifecycle` is where that fits.

## Verify

- `bun run compile` passes.
- `bun run test` passes.
- `bun run test:cli` passes.
- `bun run test:and` passes.
- `bun run test:electron` passes, which is what proves the desktop still registers its replicas after its private copy is deleted.
- `bun run tev` passes, in one run, as the final check.
- The replicate dialog's success message and what actually happened agree: the entry named in the message is on the Manage Databases page.

## Notes

- **Why the task and not the callers.** The alternative is for each caller to register the destination through the platform's own database-list methods after the task returns. That is what the desktop does today, and it is why the other two platforms do not do it at all: a behaviour implemented at the call site has to be implemented again at every call site, and nobody notices the ones that were missed. It also loses the registration when the app is killed while the replication runs, which on a phone is ordinary. `create-default-database.worker.ts` settled this question already for the database automatic import makes, and its comment says why: the thing should come to exist one way rather than one way per platform.
- **The name is where this touches the naming question.** The entry gets the destination path's last segment, and that name has to be made unique because entry names are the key of the list. `plan-database-naming.md` covers whether that should remain true. This plan does not depend on the answer, but it adds one more place that invents a name, and if the naming model changes, this is one of the places that changes with it.
- **The origin field is written twice by different things.** `replicate()` writes `origin: sourcePath` into the destination's `.db/config.json`, and the entry carries its own `origin` which is refreshed whenever the database is opened. Registration sets the entry's copy at creation so the Manage Databases page is right before the database has ever been opened.
- **Consolidation is not in scope.** `consolidate-database` requires the remote to be registered already, because that is where its credentials come from, so it has nothing to add to the list. It does record the origin on the local database, which is already listed.
