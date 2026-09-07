# Database summary in a modal

## Overview

The photo count in the navbar ("1200 photos") is the most glanced-at number in the app and is currently inert text. The database summary it summarises lives on its own page at `/database-summary`, reachable only from the sidebar's "Database Info" entry. This plan makes the count clickable: it opens the summary as a centred modal on a desktop and a sheet on a phone, the same treatment the background jobs list has just been given, so the number in the navbar leads to the detail behind it.

The summary's content is not rewritten. It is lifted out of the page into a component both the page and the new dialog render, so the two cannot drift apart.

## Issues

## Steps

1. **Extract the summary's formatting helpers.** Create `packages/user-interface/src/lib/database-summary-format.ts` and move `formatBytes` and `getStorageType` there from `packages/user-interface/src/pages/database-summary.tsx`, exporting both. Update the page to import them. Both are plain functions with no tests today; they get them in this step (see Unit Tests). The code must compile and the new tests pass before this step is complete.

2. **Extract the summary body into a shared component.** Create `packages/user-interface/src/components/database-summary-view.tsx` exporting `DatabaseSummaryView`, taking no props. Move into it everything `DatabaseSummaryPage` currently does apart from its page chrome: the `summary` / `error` / `isLoading` state, the `TaskQueue` effect that runs `get-database-summary`, the `StatTile` component and `IStatTileProps`, the stat tiles, the detail rows, and the `ConsolidateDatabaseDialog` with its `consolidateOpen` state. Keep the existing `log.info("Database summary loaded: ...")` line exactly as it is: two smoke tests wait on it. Rewrite `DatabaseSummaryPage` to render its `Box` wrapper, its "Summary" heading and `<DatabaseSummaryView />`. The page's rendered output must be unchanged. Compiles and existing tests pass before this step is complete.

3. **Add the dialog.** Create `packages/user-interface/src/components/database-summary-dialog.tsx` exporting `DatabaseSummaryDialog` with props `{ open: boolean; onClose: () => void }`. It renders `ResponsiveDialog` (from `./responsive-dialog`) with `dataId="database-summary-dialog"`, `minWidth` 420 and `maxWidth` 640, a `DialogTitle` of "Database", a `DialogContent` holding `<DatabaseSummaryView />`, and a `DialogActions` with a single Close button carrying `data-id="database-summary-dialog-close"`. Follow `packages/user-interface/src/components/jobs-dialog.tsx` for the arrangement. Compiles before this step is complete.

4. **Make the navbar count clickable.** In `packages/user-interface/src/components/navbar.tsx`, replace the `<div data-id="database-photo-count">{sortedItemsCount} photos</div>` with a `<button>` carrying the same `data-id`, which dispatches `new CustomEvent("photosphere:show-database-summary")` on `window`. It must read as clickable rather than as a label: give it a pointer cursor, a hover treatment and a `title` of "Show database summary", matching how `navbar-jobs-indicator.tsx` presents its button. The "N selected" branch beside it is unchanged. Compiles before this step is complete.

5. **Own the dialog's state in main.tsx.** In `packages/user-interface/src/main.tsx`, add a `databaseSummaryDialogOpen` state beside the existing `jobsDialogOpen`, add a `useEffect` that listens for `photosphere:show-database-summary` on `window` and opens it (cleaning the listener up on unmount, mirroring the `photosphere:show-jobs` listener directly above it), and render `<DatabaseSummaryDialog open={...} onClose={...} />` beside `<JobsDialog />`. Compiles before this step is complete.

6. **Add a story.** Create `packages/user-interface/src/stories/components/database-summary-dialog.stories.tsx` and register it in `packages/user-interface/src/stories/index.ts` alongside the other component stories. The mock platform runs no tasks, so the dialog will render its loading or empty state; that is the state worth checking fits a phone. Follow `packages/user-interface/src/stories/components/jobs.stories.tsx` for the arrangement.

7. **Extend the smoke tests.** In `apps/desktop/smoke-tests/3-open-database/test.sh`, after the existing summary assertions, navigate back to the gallery, click `database-photo-count`, wait for `database-summary-dialog` to appear and for the "Database summary loaded:" log line, then click `database-summary-dialog-close` and assert the dialog is gone. Mirror the same additions in the mobile test `apps/smoke-tests/tests/35-database-summary/test.sh` so the drawer form is covered too. Both suites must pass before this step is complete.

## Unit Tests

- `packages/user-interface/src/test/lib/database-summary-format.test.ts` (new):
  - `formatBytes` for zero bytes, for a value under a kibibyte, at each unit boundary, for a value with a fractional part, and for a value at or above 100 in its unit where it rounds to a whole number.
  - `getStorageType` for an `s3:` path and for a filesystem path.

No unit tests for `DatabaseSummaryView`, `DatabaseSummaryDialog` or the navbar change: they are React components, covered by the smoke tests below.

## Smoke Tests

- `apps/desktop/smoke-tests/3-open-database/test.sh` — clicking the navbar photo count opens `database-summary-dialog`, the summary loads into it, and the close button dismisses it.
- `apps/smoke-tests/tests/35-database-summary/test.sh` — the same on mobile, where the dialog is a drawer.
- The existing assertions in both, and in `apps/smoke-tests/tests/41-s3-database-lifecycle/test.sh`, must keep passing unchanged: they prove the extraction in step 2 did not alter the page.

## Verify

1. `bun run compile` from the repo root, clean.
2. `bun run tev` from the repo root, green. This covers the unit tests, the desktop suite and both mobile suites.
3. `bun run stories:and` renders the new dialog story at phone resolution without failures.

## Notes

- **No documentation step.** The change adds no API, no config, no command, and the repository has no user manual: `docs/` is a developer guide. There is nothing a later reader would need documented beyond the code.
- **The page stays.** `/database-summary` keeps its route and its "Database Info" sidebar entry, so the dialog is a second way in rather than a replacement. Two ways to the same content is a smell worth revisiting: once the dialog has been used for a while, the page may be worth deleting, which would also remove the nav entry and the `findTemporaryNavPage` handling for it. Left as a follow-up rather than decided here.
- **The extraction in step 2 is the risky part**, because `DatabaseSummaryPage` currently owns the task queue, the consolidate dialog and the stat rendering in one file. The existing smoke tests are what prove it still works, which is why step 2 requires them to pass before it is complete.
- **Affordance applies to both entry points.** The jobs spinner in the navbar has already been reported as not obviously clickable. Whatever treatment fixes that should be applied to the photo count in step 4 so the two match, rather than inventing a second style.
