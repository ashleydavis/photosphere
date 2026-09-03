# Automatic Import Quick Fixes

## Overview

Manual testing of automatic import on Android turned up a set of small, independent problems that each have a contained fix. None of them need a redesign: they are a missing loading state and a list that is read too late. The engine pool size moved to the import responsiveness plan, because that plan stops automatic import holding an engine for the life of the app and the two decisions cannot be made apart. The two progress steps were dropped rather than moved: `import-assets` already sends an `import-success` message per asset, and what delays it is the per-batch aggregation in the auto-import loop, which the import responsiveness plan deletes outright. Fixing the aggregation and then removing it would be wasted work. They are batched here because each one touches a different file and none depends on the others. The two larger problems found in the same session (user actions waiting behind the import, and hashing never hitting its cache) have their own plans.

## Issues

## Steps

1. **Show that a database is opening.** In `packages/user-interface/src/context/asset-database-source.tsx`, add an `isOpening` boolean to the context and set it true at the very start of `openDatabase` and false in every exit path (the unreachable case, the not-found case, and after `setDatabasePath`). Expose it through the context interface alongside the existing `isLoading`. Extract the state transitions into a plain function under `packages/user-interface/src/lib/` if any logic beyond a set/clear appears, since the context itself is not unit tested.

2. **Use the opening state in the three places a database is tapped.** In `packages/user-interface/src/components/open-database-modal.tsx`, `packages/user-interface/src/components/no-database-loaded.tsx` and `packages/user-interface/src/components/left-sidebar.tsx`, disable the list entries and show a spinner on the tapped entry while `isOpening` is true. The modal must not close until the open resolves, so the user sees the state change rather than an empty screen.

3. **Read the database list before the dialog opens.** `packages/user-interface/src/components/open-database-modal.tsx` calls `platform.getDatabases()` in an effect when it opens, so the list is empty until that returns and never updates while the dialog is open. Change it to read `dbs` from `useApp()` in `packages/user-interface/src/context/app-context.tsx`, which already holds the list in memory with a `refreshDbs`. Keep the refresh button, pointing it at the context's refresh.

4. **Raise the databases-changed notification on mobile, from the worker task that records the database.** The notification itself is already in place: `onDatabasesChanged` is on `IPlatformContext` (`packages/user-interface/src/context/platform-context.tsx`), `app-context.tsx` subscribes to it and calls `refreshDbs`, and `apps/desktop/src/main.ts` sends it where the desktop adds a database. What remains is the mobile side, which is the platform this plan was written for: `onDatabasesChanged` in `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx` returns an empty unsubscribe and nothing ever fires it, so a database automatic import creates never reaches the interface.

   Fire it from the task's completion rather than from a call in the provider. Automatic import no longer records the database through the provider at all: `packages/mobile-worker/src/lib/record-default-database.worker.ts` writes both `auto-import.toml` and `databases.toml` inside the worker, driven natively by `AutoImportService`/`AutoImportDriver` so it runs with the app off screen, and the provider's `configStore.addDatabase` is not on that path. Every completed task emits a `taskCompleted` event to the WebView (`JsEnginePlugin.onTaskSucceeded` calls `emitTaskCompleted`, and events are buffered until a listener registers), so the provider can hold the `onDatabasesChanged` callbacks in a ref and fire them from a `subscribeMobileTaskComplete` handler that matches the record-default-database task type, exactly as the sync handler at `platform-provider-mobile.tsx:445` matches `SYNC_TASK_TYPE`. Give the task type a named constant used by both the plan worker and the provider instead of repeating the string. Reading needs no change: mobile `getDatabases` goes through `mobileDatabasesConfigFile`, the same `databases.toml` the worker writes, so `refreshDbs` sees it.

   `apps/dev-frontend/src/lib/platform-provider-web.tsx` has the same empty stub and is left alone: nothing in the web build creates a database behind the interface's back, so it has nothing to report.

Every step must compile (`bun run compile`) and leave the unit tests passing before it is considered done.

## Unit Tests

- `packages/user-interface/src/test/lib/` — tests for any plain function extracted in step 1 for the opening-state transitions.
- No unit tests for the React components in steps 2 and 3, which are covered by the smoke tests below.

## Smoke Tests

- `apps/smoke-tests/` Android and iOS suites: opening a database from the open-database dialog shows the loading state and then the gallery. Assert on the `data-id` for the spinner and the existing "Open database dialog opened" log line.
- `apps/smoke-tests/` Android and iOS suites: a database created while the open-database dialog is showing appears in the list without the dialog being closed and reopened.

## Verify

- `bun run compile` succeeds.
- `bun run test` passes.
- `bun run test:everything -- --force` passes, which covers the CLI, Electron and both mobile suites.

## Notes

- A step that deleted the `checkDatabaseExists` probe from the top of `openDatabase` was dropped from this plan and must not be re-added without a fresh decision. It was worth one queued task per open, and on a busy queue during testing that task took 128 seconds, but the import responsiveness plan has since landed task priority and an interactive engine reservation, and the probe now runs at `TaskPriority.Interactive`, so the wait it was meant to remove is largely gone. Against that saving, `checkDatabaseExists` in `packages/user-interface/src/context/asset-database-source.tsx` now carries a per-call task source that fixed an intermittent failure of desktop test 26 on macOS and Windows, and it is what tells "Database not found" apart from "Could not reach the database". Removing it would move that distinction into `loadAssets`, which does not currently draw it.
