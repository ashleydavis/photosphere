# Remove the navbar's second progress indicator

## Overview

The navbar shows two indicators for running work at once. One is the jobs indicator, which names each job, shows what it is doing and offers a Cancel where the job can be cancelled. The other is an older block at `packages/user-interface/src/components/navbar.tsx` that renders the word "Loading" and a spinner whenever `isLoading` from `useAssetDatabase()` is true, and the work it stands for is `load-assets`, which is already a job in its own right: `loadAssets` in `packages/api/src/lib/load-assets.ts` tags its task with the name "Loading assets" and a `cancelSource`, so it appears in the jobs list and is counted by the indicator. So opening a database while a sync is running shows a spinner beside a chip that says two jobs, both describing the same load, and the spinner is the worse of the two: it has no name, no progress, no elapsed time and no cancel. This removes it, leaving the jobs indicator as the one place the navbar says work is happening, which is what `docs/background-tasks.md` and the repository's own rule already say it should be.

## Issues

## Steps

1. **Delete the block.** In `packages/user-interface/src/components/navbar.tsx`, remove the conditional that renders the "Loading" label and `<Spinner show={true} />` when `isLoading` is true (it sits between the `ml-auto` spacer and `<NavbarJobsIndicator />`), and remove `isLoading` from the `useAssetDatabase()` destructuring at the top of the component if nothing else in the file uses it. Leave `isSyncing` and the hidden `navbar-sync-state` span alone: that span is read by the smoke tests and renders no visible chrome. This is a React component, so it gets no unit test and is covered by the smoke tests below. `bun run compile` must pass before this step is finished.

2. **Deal with the orphaned component.** After step 1 the only remaining users of `packages/user-interface/src/components/spinner.tsx` are its own stories (`packages/user-interface/src/stories/components/spinner.stories.tsx`). Decide with the evidence rather than by assumption: grep for `<Spinner` and for imports of `./spinner` across `packages/` and `apps/` and, if the stories are genuinely the only ones left, delete both the component and its stories file, and remove the story's entry from wherever the stories index lists it. A component kept alive only by a story of itself is a component nobody renders. `bun run compile` must pass before this step is finished.

3. **Assert the one indicator that remains.** The removed element carries no `data-id`, so the harness cannot assert its absence: the bridge reads values by `data-id` and has no general DOM query. Cover what can be covered, which is that the jobs indicator does the job the spinner was doing. In `apps/smoke-tests/tests/3-open-database/test.sh`, assert that `navbar-jobs-indicator` appears while the database is opening and that `navbar-jobs-count` returns to `0` once it has, which is the pattern `apps/desktop/smoke-tests/17-replicate-database/test.sh` already uses for a replication. Watch it fail first by asserting a wrong count.

4. **Check the stories still render.** Run `bun run stories` and confirm the navbar stories and the gallery stories still render with no missing component, since step 2 may remove a component a story imports. The screenshots are also where the visual change is seen: one indicator in the navbar rather than two.

5. **Update the documentation to match the code**, including whether the spinner component was deleted. The document affected is `docs/background-tasks.md`, which should say the jobs indicator is the only thing in the navbar reporting running work.

## Unit Tests

- None for the navbar: it is a React component, and this change removes markup rather than logic. The repository does not unit test components, contexts or hooks.
- No function changes anywhere else. If step 2 finds a caller that keeps `spinner.tsx` alive and the component stays, nothing is added there either: it has no logic beyond a boolean guard.

## Smoke Tests

- `apps/smoke-tests/tests/3-open-database`: the jobs indicator appears while a database opens and `navbar-jobs-count` returns to `0` afterwards.
- `apps/desktop/smoke-tests/17-replicate-database` already asserts the count clearing after a replication and must keep passing, which is what proves the indicator that remains is the one carrying the load.

## Verify

- `bun run compile` passes.
- `bun run test` passes.
- `bun run test:electron` passes.
- `bun run test:and` passes.
- `bun run tev` passes, in one run, as the final check.
- `bun run stories` completes and the navbar screenshots show a single indicator.

## Notes

- **`isLoading` itself stays.** It is read from `useAssetDatabase()` by `gallery-context.tsx`, which passes it to `pages/gallery/gallery.tsx` (the centred spinner shown only while the gallery holds no items at all) and to `right-sidebar.tsx` (which disables two menu actions while a load runs). Neither is a duplicate of the jobs indicator: one is an empty-state placeholder and the other is a disabled control. Only the navbar's copy goes.
- **The load is genuinely a job already.** `loadAssets` queues `load-assets` at `TaskPriority.Interactive` with `job: { id: "load:<databasePath>", name: "Loading assets", cancelSource: databasePath }`, so the row is named, counted and cancellable. Nothing is lost by removing the spinner, and the user gains a name and a Cancel for work that had neither.
- **Why this happened is worth knowing:** the spinner predates jobs, and adding the job tag to `load-assets` gave the same work a second, better indicator without the first one being taken out. Anything else with an indicator of its own is likely to be the same story, which is what the documentation step is for.
