# Automatic Import Quick Fixes

## Overview

Manual testing of automatic import on Android turned up a set of small, independent problems that each have a contained fix. None of them need a redesign: they are a missing loading state, a redundant task, and a list that is read too late. The engine pool size moved to the import responsiveness plan, because that plan stops automatic import holding an engine for the life of the app and the two decisions cannot be made apart. The two progress steps were dropped rather than moved: `import-assets` already sends an `import-success` message per asset, and what delays it is the per-batch aggregation in the auto-import loop, which the import responsiveness plan deletes outright. Fixing the aggregation and then removing it would be wasted work. They are batched here because each one touches a different file and none depends on the others. The two larger problems found in the same session (user actions waiting behind the import, and hashing never hitting its cache) have their own plans.

## Issues

## Steps

1. **Show that a database is opening.** In `packages/user-interface/src/context/asset-database-source.tsx`, add an `isOpening` boolean to the context and set it true at the very start of `openDatabase` and false in every exit path (the unreachable case, the not-found case, and after `setDatabasePath`). Expose it through the context interface alongside the existing `isLoading`. Extract the state transitions into a plain function under `packages/user-interface/src/lib/` if any logic beyond a set/clear appears, since the context itself is not unit tested.

2. **Use the opening state in the three places a database is tapped.** In `packages/user-interface/src/components/open-database-modal.tsx`, `packages/user-interface/src/components/no-database-loaded.tsx` and `packages/user-interface/src/components/left-sidebar.tsx`, disable the list entries and show a spinner on the tapped entry while `isOpening` is true. The modal must not close until the open resolves, so the user sees the state change rather than an empty screen.

3. **Stop probing before opening.** In `packages/user-interface/src/context/asset-database-source.tsx`, delete the `checkDatabaseExists` helper and its call at the top of `openDatabase`. Opening must proceed straight to setting the database path and loading, with the load path reporting a database that is absent or unreachable. Check what `loadAssets` currently does when the path holds no database, and make it return a result that distinguishes "the storage answered and held no database" from "the storage could not be reached", so the two existing toasts ("Database not found" and "Could not reach the database") keep their present meanings. Leave the `check-database-exists` task handler registered: `apps/desktop/src/main.ts` calls `checkDatabaseExists` directly for automatic import and that use stays.

4. **Read the database list before the dialog opens.** `packages/user-interface/src/components/open-database-modal.tsx` calls `platform.getDatabases()` in an effect when it opens, so the list is empty until that returns and never updates while the dialog is open. Change it to read `dbs` from `useApp()` in `packages/user-interface/src/context/app-context.tsx`, which already holds the list in memory with a `refreshDbs`. Keep the refresh button, pointing it at the context's refresh.

5. **Refresh the in-memory list when automatic import creates a database.** `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx` adds the default database through `configStore.addDatabase` without anything telling the interface. Add a databases-changed notification to the platform context in `packages/user-interface/src/context/platform-context.tsx`, raise it from the mobile provider after `addDatabase` and `setDefaultDatabasePath`, raise it from the desktop equivalent in `apps/desktop/src/main.ts` where the same thing happens, and have `app-context.tsx` subscribe and call `refreshDbs`.

Every step must compile (`bun run compile`) and leave the unit tests passing before it is considered done.

## Unit Tests

- `packages/user-interface/src/test/lib/` — tests for any plain function extracted in step 2 for the opening-state transitions.
- `packages/node-api/src/test/lib/auto-import.worker.test.ts` — the per-item progress subscription added in step 5: one message per imported photo, counters increasing, unsubscribed when the batch ends.
- `packages/api/src/test/lib/auto-import-loop.test.ts` — extend the existing tests so an arrival reported mid-batch is not reported a second time at the end of the batch.
- `packages/user-interface/src/test/` — a test for whatever function step 4 introduces to tell "no database here" from "could not reach the storage".
- No unit tests for the React components in steps 3 and 7, which are covered by the smoke tests below.

## Smoke Tests

- `apps/smoke-tests/` Android and iOS suites: opening a database from the open-database dialog shows the loading state and then the gallery. Assert on the `data-id` for the spinner and the existing "Open database dialog opened" log line.
- `apps/smoke-tests/` Android and iOS suites: a database created while the open-database dialog is showing appears in the list without the dialog being closed and reopened.
- Android and iOS suites: automatic import of a small seeded library reports progress more than twice, proving progress is per photo rather than per batch.
- `bun run test:electron`: the desktop open-database path still reports "Database not found" for a path with no database and still opens a real one, after `check-database-exists` is dropped from the open path.

## Verify

- `bun run compile` succeeds.
- `bun run test` passes.
- `bun run test:everything -- --force` passes, which covers the CLI, Electron and both mobile suites.
- On a device or emulator with automatic import running, tapping a database shows an immediate loading state and the gallery arrives without the two minute wait seen in testing.

## Notes

- The engine pool raise in step 1 is listed first because everything else in the mobile app is easier to observe once tasks are not starved. It is not a fix for the starvation itself, which is covered by the responsiveness plan.
- Step 4 removes a task from the open path, which is worth roughly one queued task per open. On a busy queue during testing that single task took 128 seconds, so the saving is real, but the underlying problem is the queueing and belongs to the responsiveness plan.
- The desktop uses `checkDatabaseExists` directly (not as a task) in `apps/desktop/src/main.ts` for automatic import. That call is not affected.
- Steps 5 and 6 share one subscription. They are separate steps because the first changes what the progress card shows and the second changes when photos land in the gallery, and each can be verified on its own.
- Open question for step 4: `loadAssets` may currently treat an unreachable database and an empty one the same way. If it does, the distinction has to be added there before the probe can be removed without losing the two different messages.
