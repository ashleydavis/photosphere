# Unified import failure reporting across all platforms

## Overview

Importing photos can fail in two completely different ways and each is reported through a different mechanism. A picker failure (for example iOS failing to copy a chosen photo out of the photo library) arrives as a rejected promise that must be caught at the call site, while a failure inside the background `import-assets` task arrives as a task-completion result that the import context currently discards. The result is inconsistent behaviour across Electron, web, iOS and Android, and a user who hits the second kind of failure sees the import stall with no explanation. This plan collapses both into a single failure channel owned by `ImportContextProvider`, so every platform reports import failures identically, everything after the file picker keeps running in the background task, and the import page becomes a passive renderer of one failure state instead of holding its own try/catch. It also aligns the four `pickFiles` implementations on one contract so a cancel and a failure are never confused for one another.

## Still outstanding: the user is never shown import errors

This is the point of the plan and it is not solved anywhere yet. It was confirmed by running the real desktop app, not by reading code.

What was observed: the Electron app was driven to drop two files onto the import drop zone, one valid JPEG and one file named `broken.jpeg` holding the bytes `this is not a jpeg`. The corrupt file failed to hash, and every trace of it disappeared. The page reported `1 added, 0 skipped, 0 failed` with a single row, and the completion toast read `Import complete: 1 asset added` in green. Nothing anywhere told the user that a file they dropped had not been imported. The log recorded the failure; the interface did not.

Two distinct defects produce that, both still present:

- `import-pending` is only sent by `upload-asset.worker.ts`, which never runs when the earlier hash-file task fails. The `import-failed` message that `import-assets.worker.ts` does send then arrives with an `assetId` that has no matching item, and the `import-failed` branch in `ImportContextProvider` only maps over existing items. The failure is dropped on the floor.
- The completion toast in `main.tsx` counts only items with status `success` and hardcodes `color: 'success'`, so an import that ended with failures is reported as a clean success regardless.

Fixing either alone is not enough: without the first, the failure never reaches the item list, and without the second, the toast would not report it even if it did.

## Issues

## Steps

1. **Audit and align the picker contract across all four platforms.** Read the `pickFiles` implementation in `apps/desktop-frontend/src/lib/platform-provider-electron.tsx`, `apps/dev-frontend/src/lib/platform-provider-web.tsx`, `packages/mobile-frontend/src/lib/mobile-platform-tasks.ts` (`pickMobileFiles`), plus the native `pickFiles` in `apps/ios-frontend/ios/App/App/JsEngine/JsEnginePlugin.swift` and `apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/JsEnginePlugin.java`, and the Electron `pick-files` IPC handler and the dev-server `pick-files` message handler. Establish one documented contract in the `pickFiles` doc comment on `IPlatformContext` in `packages/user-interface/src/context/platform-context.tsx`: resolve with a non-empty path array on success, resolve `undefined` when the user cancelled, reject with an `Error` when the pick itself failed. Change any implementation that currently swallows a failure into a cancel so that it rejects instead. Do not add test-only hooks to make failures reachable. The step is complete when the code compiles and all existing unit tests pass.

2. **Create the failure-description library.** Add `packages/user-interface/src/lib/import-failure.ts` containing three plain functions and their supporting named interfaces, all with `//` comment blocks:
   - `describePickerFailure(error: Error): string` returning the user-facing message for a rejected picker call.
   - `describeTaskFailure(result: Record<string, unknown>): string | undefined` reading the `status` and `errorMessage` fields of a task-completion result (see `ITaskResult` in `packages/task-queue/src/lib/types.ts`) and returning a message only when the task failed, otherwise `undefined`.
   - `summariseImport(items: IImportItem[]): IImportSummary` returning a named interface carrying the completion message and the toast colour, derived from the success, skipped and failure counts.
   Import `IImportItem` from `packages/user-interface/src/context/import-context.tsx`. The step is complete when the code compiles and the unit tests listed below pass.

3. **Extend the import context state to carry a failure.** In `packages/user-interface/src/context/import-context.tsx`, add `'failed'` to the `ImportStatus` union and add an `errorMessage: string | undefined` field to `IImportContext`, each with a `//` comment. Add the matching `useState` in `ImportContextProvider` and include it in the provided context value. Ensure `clearImport` resets it. The step is complete when the code compiles and all existing unit tests pass.

4. **Route picker failures into that state.** In `beginImportSession` in `packages/user-interface/src/context/import-context.tsx`, wrap the awaited session promise so a rejection is converted through `describePickerFailure`, stored in `errorMessage`, and the status set to `'failed'`, returning `false`. Cancellation (an `undefined` session) must remain distinct and must not set a failure. The step is complete when the code compiles and all existing unit tests pass.

5. **Route background task failures into the same state.** In the `platform.onTaskComplete` subscription in `ImportContextProvider`, stop discarding the result. Pass it through `describeTaskFailure`; when a message comes back, store it in `errorMessage` and set the status to `'failed'` instead of marking `addPathsDoneRef` and running the completion check. When no message comes back, keep the existing behaviour. The step is complete when the code compiles and all existing unit tests pass.

6. **Make the import page a passive renderer of the failure.** In `packages/user-interface/src/pages/import/import-page.tsx`, delete the try/catch and the `addToast` call currently inside `handleImportFiles`, returning it to a bare `await startImportFiles()`. Consume `status` and `errorMessage` from `useImport()` and add a `useEffect` that raises a `danger` toast through `useToast` when `errorMessage` transitions from undefined to set. Render an inline error panel when `status === 'failed'` showing the same message, carrying `data-id="import-error"` so the smoke driver can find it. The step is complete when the code compiles, all unit tests pass, and the smoke tests listed below pass.

7. **Add the completion summary toast.** In the same page, raise a single toast when `status` transitions to `'completed'`, using `summariseImport` to build the message and colour so an import that finished with per-item failures is reported as such rather than silently looking successful. The step is complete when the code compiles, all unit tests pass, and the smoke tests pass.

8. **Confirm nothing else can move into the background task.** Read `importFiles`, `importDirectories` and `startImportWithPaths` in `packages/user-interface/src/context/import-context.tsx` and verify that the only work remaining on the UI side after this plan is the picker call itself and the React state that renders the page. Record the finding in the doc comment on `startImportWithPaths`. Do not attempt to move the picker into the background task: see Notes. The step is complete when the code compiles and all unit tests pass.

9. **Stop dropping a failure that arrives with no matching item.** In the `import-failed` branch of the `platform.onTaskMessage` subscription in `packages/user-interface/src/context/import-context.tsx`, append a new `IImportItem` with status `failure` (using the message's `assetId` and `logicalPath`) when no item with that `assetId` is already in the list, instead of mapping over the existing items and silently matching nothing. This is what currently makes a file that fails before `upload-asset` runs vanish from the interface entirely. The step is complete when the code compiles, all unit tests pass, and the behaviour is confirmed by driving the real app as described under Verify.

10. **Make the existing completion toast tell the truth.** In the import-completion `useEffect` in `packages/user-interface/src/main.tsx`, replace the hardcoded success message and `color: 'success'` with the output of `summariseImport` from step 2, so an import that ended with failures is reported as a failure. Do not add a second toast on the import page: this toast already exists and a page-level one duplicates it. The step is complete when the code compiles, all unit tests pass, and the behaviour is confirmed by driving the real app as described under Verify.

11. **Update the background-tasks guide.** Add a short section to `docs/background-tasks.md` describing the single import failure channel: picker rejection and task failure both land in `ImportContextProvider` and surface as one toast plus one inline error, identically on all four platforms. The step is complete when the document is written.

## Unit Tests

Add `packages/user-interface/src/test/lib/import-failure.test.ts` covering:

- `describePickerFailure` returns the error's message for a normal `Error`.
- `describePickerFailure` returns a usable message when the error has an empty message.
- `describeTaskFailure` returns `undefined` for a successful task result.
- `describeTaskFailure` returns the `errorMessage` for a failed task result.
- `describeTaskFailure` returns a fallback message for a failed task result carrying no `errorMessage`.
- `describeTaskFailure` returns `undefined` for a result object missing a `status` field.
- `summariseImport` reports a success message and success colour when every item succeeded.
- `summariseImport` reports the failure count and a warning or danger colour when at least one item failed.
- `summariseImport` includes the skipped count when items were skipped.
- `summariseImport` handles an empty item list.

Extend `packages/user-interface/src/test/context/import-context.test.ts` covering:

- `importFiles` propagates a rejection from `platform.pickFiles` to its caller rather than resolving.
- `importFiles` still returns `undefined` without queueing a task when the picker resolves `undefined` (cancel), proving cancel and failure stay distinct.

`ImportContextProvider`, `ImportPage` and `useToast` are a context, a component and a hook, so they are not unit tested. They are covered by the smoke tests below.

## Smoke Tests

Add `apps/smoke-tests/tests/47-import-task-failure/test.sh`, modelled on `apps/smoke-tests/tests/4-import-photos/test.sh`, which:

- Resets config, seeds the `no-assets` fixture database and opens it.
- Navigates to the import page and waits for `Import page ready`.
- Stages a picked path that cannot be imported (a sandbox-relative path with no file behind it) via the existing `pick-files` control command, then clicks `import-files-button`. This drives the real `import-assets` task to a genuine failure through the normal user path, with no test-only hook.
- Asserts the failure log line appears and that the element carrying `data-id="import-error"` is present.
- Navigates to the gallery and asserts `Gallery loaded: 0 assets`, proving a failed import adds nothing.
- Uses `check_no_errors` with the expected import failure pattern allowed through.

Extend `apps/smoke-tests/tests/4-import-photos/test.sh` to assert the completion summary toast text after `2 assets imported`, so the success half of step 7 is covered end to end.

Both tests must pass on the Electron suite (`bun run test:electron`) and the Android suite (`bun run test:and`), which is what proves the behaviour is the same on desktop and mobile.

There is deliberately no smoke test for a picker failure. That failure originates inside the native picker, which no automated suite on the development machine can drive, and faking it would require a test-only backdoor in shared code. It is covered by the native `PickFilesCopyFailureTests` XCTest on iOS instead.

## Verify

- `bun run compile` exits 0.
- `bun run test` exits 0 with the new `import-failure.test.ts` and the extended `import-context.test.ts` passing.
- `bun run test:electron` exits 0 with the new test 47 passing.
- `bun run test:and` exits 0 with the new test 47 passing and the expected test count raised by one.
- `git diff` shows no test-only sentinel, seed or inject function added to `packages/user-interface` or `packages/mobile-frontend`.
- The desktop app is driven by hand and the result looked at, because the defects in "Still outstanding" were invisible in the code and in the logs and only showed up on screen. Build with `bun run bundle` in `apps/desktop-frontend` then `apps/desktop`, launch the app the way `apps/desktop/smoke-tests/lib/common.sh` does (`start_app` sets `PHOTOSPHERE_TEST_MODE=1` and prints the control port), then drive it over the control server: open a database, click `import-button`, and post a `drop` command for `import-drop-zone` carrying one valid image and one file named with an image extension containing junk bytes. Capture the window with the control server's `/screenshot` endpoint and read the image. The import must report one added and one failed, the failed file must appear as its own row, and the completion toast must be the failure colour and name the failure count.

## Notes

- **The file picker cannot move into the background task, on any platform.** On the web a file dialog requires a trusted user gesture, so a picker opened in response to a worker message is refused by the browser. On iOS and Android the embedded JS engine (JavaScriptCore and QuickJS) has no UI and cannot present a `PHPicker` or an Android `ACTION_OPEN_DOCUMENT` intent, so a background task would have to call back through the host bridge into native, hop to the main thread, and hold the continuation across a possible app suspension. That is a longer and more fragile path than the current one. Electron alone could do it, and being the only platform where it works is the problem this plan is trying to remove.
- Everything after the picker already runs in the background `import-assets` task on all four platforms, so the cross-platform inconsistency being fixed here is entirely in how failures are reported, not in where the work happens.
- `onTaskComplete` is documented as never firing on web (see `IPlatformContext` in `packages/user-interface/src/context/platform-context.tsx`). Step 5 therefore improves desktop, iOS and Android; on web the import page keeps its existing behaviour. Do not add a web-only workaround as part of this plan.
- The per-item statuses already rendered by the import page (`pending`, `success`, `failure`, `skipped`) are unchanged. This plan adds a session-level failure on top of them, for the case where the whole import stops rather than an individual file failing.
- The try/catch removed in step 6 was added as a stopgap in the `step-23-ios-photo-copy` worktree. If that worktree has not merged when this plan is executed, step 6 becomes a straight replacement rather than a removal.
