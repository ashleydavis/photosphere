# Dissolve the platform context

## Overview

Ziggy is the only platform Photosphere runs on, so the injected platform abstraction is no longer needed. Today `apps/photosphere-frontend/src/lib/platform-provider-ziggy.tsx` (`PlatformProviderZiggy`) turns about fifty Ziggy messages and events into the members of `IPlatformContext` (`packages/user-interface/src/context/platform-context.tsx`), and 27 components and contexts in `packages/user-interface/src` reach them through `usePlatform()`. This plan deletes `PlatformProviderZiggy`, `IPlatformContext`, `PlatformContextProvider`, `usePlatform` and `mockPlatform`. Each caller in `user-interface` calls a plain function that talks to the Ziggy bridge directly, events go through the existing `AppMessages` hub, and the work the provider did that no component asks for (background import and sync, menu items, `page-loaded`, test mode) moves into `App` in `apps/photosphere-frontend/src/app.tsx`, the component that hosted the provider. Behaviour is unchanged: every function keeps the body and comments of the member it replaces. Nothing beyond that is redesigned.

## Issues

## Steps

1. **Dependencies.** In `packages/user-interface/package.json` add `"ziggy"` with the exact specifier in `apps/photosphere-frontend/package.json` (`git+https://github.com/ashleydavis/ziggy.git#v0.0.23`) and `"eruda": "^3.0.0"`. Run `bun install` at the repo root. `bun run compile` passes.

2. **Move the data types.** Create `packages/user-interface/src/lib/ziggy/core-types.ts` and move into it, with their comments, every type `platform-context.tsx` exports except `IPlatformContext`, `IPlatformContextProviderProps`, `PlatformContextProvider` and `usePlatform` (`INetworkStatus`, `Unsubscribe`, `IMenuActionEvent`, `IDevToolsStateEvent`, `IPlatformEvent`, `IS3Credentials`, `IEncryptionKeyPair`, `ISharedSecretEntry`, `IDatabaseEntry`, `IShowNotificationLink`, `IShowNotificationData`, `IUpdateAvailableData`, `IDownloadAssetItem`, `IImportSession`, `IToolStatus`, `IPickFolderOptions`, `IToolsStatus`, `ISaveDownloadResult` and any other exported type found in the file). `platform-context.tsx` imports what `IPlatformContext` needs from `core-types.ts` and re-exports nothing. Change every import of these types from `platform-context` (find them with `git grep -n "platform-context" -- packages apps`) to `core-types`, and export `core-types.ts` from `packages/user-interface/src/index.tsx` in place of the type exports from `platform-context`. Keep `IPlatformContext`, `PlatformContextProvider` and `usePlatform` exported until step 9. `bun run compile` passes.

3. **Move the helpers into `user-interface`.** Copy each file below into `packages/user-interface/src/lib/ziggy/` and its test into `packages/user-interface/src/test/lib/ziggy/` (the originals are removed in Clean up), fixing imports (`mobile-export.ts` takes `ISaveDownloadResult` from `./core-types`). Export each from `packages/user-interface/src/index.tsx`.
    - `apps/photosphere-frontend/src/lib/app-messages.ts`. Change `onEvent` to return an `Unsubscribe` that removes only that callback, add `emit<TData>(type: string, data: TData): void`, which hands `data` to the callbacks for `type` exactly as `receive` does (for events that start in the page), and remove `removeAllListeners`. Update the class comment. In the copied test, replace the `removeAllListeners` cases with cases for the returned `Unsubscribe` and add cases for `emit`.
    - `to-json-value.ts`, `mobile-export.ts`, `dropped-file-path.ts`, `test-mode.ts` (each from `apps/photosphere-frontend/src/lib/`), unchanged.
    - `apps/photosphere-frontend/src/test/fake-ziggy.ts` goes to `packages/user-interface/src/stories/mocks/fake-ziggy.ts` (no test of its own).
    - Change `apps/photosphere-frontend/src/app.tsx`, `main.tsx`, `lib/mcp-tool-handler.tsx` and every test under `apps/photosphere-frontend/src/test` that imports one of these files to import it from `user-interface`. In `mcp-tool-handler.tsx` replace the `removeAllListeners(MCP_TOOL_REQUEST)` cleanup with the `Unsubscribe` that `onEvent` returns.
    - `bun run compile` and `bun run test` pass.

4. **Add the Ziggy context.** Create `packages/user-interface/src/context/ziggy-context.tsx`, with no logic in it:
    - `IErudaState` (moved from the provider: `initialised`, `visible`) and `IExportTestState` (`staged: ExportTestOutcome | undefined`, the outcome a test staged for the next phone export).
    - `IZiggyContext`: `ziggy: IZiggyBridge`, `platform: IPlatformInfo`, `messages: AppMessages`, `erudaState: IErudaState`, `exportTestState: IExportTestState`.
    - `ZiggyContextProvider({ value, children })` and `useZiggy(): IZiggyContext`, which throws `ZiggyContext is not set! Add ZiggyContextProvider to the component tree.` when none is mounted.
    - Export from `index.tsx`. `bun run compile` passes.

5. **Add the plain functions.** In `packages/user-interface/src/lib/ziggy/`, one function per `IPlatformContext` member listed, each taking the bridge first and then whatever else the old member read from the provider, with the old member's body and comments. Export all from `index.tsx`.
    - `databases.ts`: `openDatabase(ziggy, platform)`, `notifyDatabaseOpened(ziggy, messages, databasePath)` (invokes `notify-database-opened`, then `messages.emit('database-chosen', databasePath)` in place of `recordSyncDatabase`, then `messages.emit('database-opened', databasePath)` in place of the opened callbacks), `notifyDatabaseClosed(ziggy)`, `notifyDatabaseEdited(ziggy)`, `getDatabases`, `addDatabase`, `updateDatabase`, `setDatabaseOrigin`, `removeDatabaseEntry`, `findDatabase`.
    - `recents.ts`: `getRecentDatabases`, `getLastDatabase`, `removeRecentDatabaseName`.
    - `vault.ts`: `listSecrets`, `addSecret`, `updateSecret`, `deleteSecret`, `getSecretValue`.
    - `host.ts`: `openFolder(ziggy, platform, folderPath)`, `pickFolder`, `pickFiles`, `getPathForFile(ziggy, platform, file)` (uses `isTestMode()`), `checkTools(ziggy, platform)`, `copyToClipboard(platform, blob, contentType)`, `toggleDevTools(ziggy, platform, erudaState)`, `saveDownloadedFiles(ziggy, platform, uuidGenerator, exportTestState, items, databasePath)` (reads and clears `exportTestState.staged`; `runDownloadTask` becomes a private function in this file taking `uuidGenerator`), `cancelTasks`, `setSyncAllowed`, `listS3Dirs`, `importSharePayload`, `markUpdateAsShown`, `markNewsAsShown`, `backgroundImportDescription(platform): string` and `supportsDragAndDropImport(platform): boolean`.
    - `task-events.ts`: `onTaskMessage(ziggy, handler): Unsubscribe` and `onTaskComplete(ziggy, handler): Unsubscribe`, each registering its own `ziggy.onTaskEvent` / `ziggy.onTaskCompleted` listener that calls the handler inside `flushSync` (as the provider did) and returning the call that removes that listener.
    - Members with no function: `registerAction` and `runAction` become `ziggy.registerAction`/`ziggy.removeAction`/`ziggy.runAction` at their one caller each, `getNetworkStatus`/`onNetworkStatusChange` become `readBrowserNetworkStatus`/`subscribeBrowserNetworkStatus`, the six LAN share members come from `useLanShareTasks()`, and every `on<Event>` member becomes `messages.onEvent('<channel>', callback)` (step 7 lists the channels).
    - Unit tests for every function in `packages/user-interface/src/test/lib/ziggy/`, using `FakeZiggy`. `bun run compile` and `bun run test` pass.

6. **Move the app-level work into `App`.** In `apps/photosphere-frontend/src/app.tsx`:
    - Move from the provider: the `uuidGenerator` constant, `BACKGROUND_WORK_CONFIG_KEYS`, and every effect that is not a member: `seedSyncSettings`, the background work effect, the import progress log (through `onTaskMessage`), `navigate`, `runMenuEffect` and the menu listener, `page-loaded`, the test-mode window events with `signalTestPageReady`, and the visibility listener. Keep their comments.
    - Build the `IZiggyContext` once with `useState(() => ...)` (`new AppMessages(ziggy)`, fresh `erudaState` and `exportTestState`). Build `config` and `state` with `createConfig` as the provider did; the config writer calls `messages.emit('background-work-settings-changed', key)` for a key in `BACKGROUND_WORK_CONFIG_KEYS` in place of `autoImportChangedRef`.
    - Replace the provider's callback sets: the background work effect subscribes to `background-work-settings-changed` and to `database-chosen` (whose callback runs `recordSyncDatabase` and then re-plans), `runMenuEffect` uses `messages.emit('database-closed', null)` and `messages.emit('platform-event', ...)`, the test open-database handler emits `database-opened` then calls `notifyDatabaseOpened`, the seeded news handler emits `show-notification`, the stage-export handler sets `exportTestState.staged`, and the visibility listener emits `database-content-changed`.
    - Render `UuidGeneratorProvider`, `ConfigContextProvider`, `StateContextProvider` and `ZiggyContextProvider` around the `HashRouter`, and remove both `PlatformProviderZiggy` wrappers from the routes. The provider file is no longer imported. `App` is the outermost component, so its effects still run after every child's.
    - `bun run compile` passes.

7. **Change the callers.** In each of the 27 files `git grep -l "usePlatform" -- packages/user-interface/src ':!packages/user-interface/src/stories' ':!packages/user-interface/src/context/platform-context.tsx'` lists, plus `packages/user-interface/src/stories/stories-page.tsx`, replace `const platform = usePlatform()` with `const { ziggy, platform, messages, erudaState, exportTestState } = useZiggy()` (only the fields the file uses) and each member as follows. Dependency arrays that named `platform` name what the effect now uses.
    - Request members: `platform.X(args)` becomes `X(ziggy, args)` with the extra arguments from step 5.
    - Events: `onDatabaseOpened` is `messages.onEvent('database-opened', ...)`, likewise `onDatabaseClosed` `database-closed`, `onThemeChanged` `theme-changed`, `onSyncStarted` `sync-started`, `onSyncCompleted` `sync-completed`, `onShowNotification` `show-notification`, `onDatabasesChanged` `databases-changed`, `onUpdateAvailable` `update-available`, `onPlatformEvent` `platform-event`, `onDatabaseContentChanged` `database-content-changed`. `onTaskMessage`/`onTaskComplete` use step 5's functions.
    - `platform.backgroundImportDescription` and `platform.supportsDragAndDropImport` call the step 5 functions with the `IPlatformInfo`.
    - `import-context.tsx`: `IImportOrchestrationDeps.platform` becomes `ziggy: IZiggyBridge` and the helpers call `pickFolder(deps.ziggy, ...)` and `pickFiles(deps.ziggy, ...)`. In `packages/user-interface/src/test/context/import-context.test.ts`, replace `makePlatform` with a `FakeZiggy` whose `pick-folder`/`pick-files` replies are what the overrides returned; the assertions stay as they are.
    - `bun run compile` and `bun run test` pass.

8. **Stories.** In `packages/user-interface/src/stories/mocks/index.tsx` replace `mockPlatform()` with `mockZiggyContext(): IZiggyContext` over a `FakeZiggy` whose `replies` are seeded, for every message the step 5 functions invoke, with the reply that makes the function return what the `mockPlatform` member returned (`null` where it returned `undefined`). `MockProviders` takes `ziggyContext?: IZiggyContext` in place of `platform` and mounts `ZiggyContextProvider` in place of `PlatformContextProvider`; `RealDatabaseProviders` likewise. In `databases.stories.tsx`, `secrets.stories.tsx`, `open-database-modal.stories.tsx`, `s3-browser-modal.stories.tsx` and `select-secret-modal.stories.tsx`, each `platform.X = async () => value` becomes `context.ziggy.replies.set('<message X invokes>', value)` in the shape that message replies with (`vault-list` replies with `ISecret` entries). `bun run compile` passes and `bun run stories:ziggy` renders every story without a crash.

9. **Documentation.** Update:
    - `apps/photosphere-frontend/README.md` lines 9-10: drop the platform provider entry; say `App` in `src/app.tsx` runs the background work, the menu items, `page-loaded` and test mode, and that the shared UI reaches the core through `useZiggy()` and the functions in `packages/user-interface/src/lib/ziggy/`.
    - `docs/photosphere-on-ziggy.md` line 10: the `ziggy` specifier is in both `apps/photosphere-frontend/package.json` and `packages/user-interface/package.json`. Line 24: the UI talks to `window.ziggy` through `ZiggyContext` and `lib/ziggy`, with only the queue backend in `apps/photosphere-frontend`. Line 29: `app-messages.ts` path, the menu event handled by `App`, and `registerAction`/`runAction` called on the bridge.
    - `docs/toast-notifications.md` line 29: `messages.onEvent('show-notification', callback)`.
    - `docs/development.md` line 36: drop "platform provider".

10. **Clean up.** Delete `apps/photosphere-frontend/src/lib/platform-provider-ziggy.tsx`, `packages/user-interface/src/context/platform-context.tsx`, and the originals copied in step 3 (`apps/photosphere-frontend/src/lib/app-messages.ts`, `to-json-value.ts`, `mobile-export.ts`, `dropped-file-path.ts`, `test-mode.ts`, `apps/photosphere-frontend/src/test/fake-ziggy.ts`, and `app-messages.test.ts`, `to-json-value.test.ts`, `mobile-export.test.ts`, `dropped-file-path.test.ts`, `test-mode.test.ts` under `apps/photosphere-frontend/src/test`). Remove the `platform-context` exports from `packages/user-interface/src/index.tsx` and `"eruda"` from `apps/photosphere-frontend/package.json`, then run `bun install`. `git grep -n "usePlatform\|IPlatformContext\|PlatformContextProvider\|mockPlatform\|PlatformProviderZiggy" -- apps packages` prints nothing (the `mockPlatform` jest mock in `packages/node-utils/src/test/lib/data-dirs.test.ts` is unrelated and stays). Run `bun run tev`; it passes.

## Unit Tests

All in `packages/user-interface/src/test/lib/ziggy/`, with `FakeZiggy`:

- `app-messages.test.ts`: the moved cases, plus `onEvent`'s `Unsubscribe` removes only its own callback, and `emit` reaches the callbacks for its type and no others.
- `databases.test.ts`: each function sends the right name and data and maps the reply (`findDatabase` turns `null` into `undefined`; `openDatabase` sends nothing on mobile; `notifyDatabaseOpened` emits `database-chosen` and `database-opened` after the invoke).
- `recents.test.ts`, `vault.test.ts`: names, data and reply mapping (`addSecret` throws for an existing name; `updateSecret` sets before deleting on a rename and sends nothing without a value).
- `host.test.ts`: `openFolder`/`checkTools` desktop and mobile branches, `pickFolder`/`pickFiles` `null` to `undefined`, `cancelTasks`/`setSyncAllowed` `main-command` payloads, `backgroundImportDescription` for desktop, iOS and Android, `supportsDragAndDropImport`, `saveDownloadedFiles` desktop branch and that it clears `exportTestState.staged`.
- `task-events.test.ts`: the handler receives each task event and completion, and the returned call removes the listener.
- Moved unchanged: `to-json-value.test.ts`, `mobile-export.test.ts`, `dropped-file-path.test.ts`, `test-mode.test.ts`.
- Updated: `packages/user-interface/src/test/context/import-context.test.ts` (step 7).

`ziggy-context.tsx`, `App` and the callers are React components and contexts, so they are covered by the smoke tests, not unit tests.

## Smoke Tests

- `bun run test:ziggy`: the Photosphere App smoke tests on the host cover opening a database, the menu, toasts, import, sync, export and test mode through `App` and the changed callers.
- `bun run test:ziggy:and`: the same on the Android emulator pool, covering the phone branches (background import, Eruda, share-sheet export). Part of `bun run tev`.
- `bun run stories:ziggy`: renders every story through the new mocks and fails on any story that crashes.

## Verify

- `bun run compile` passes.
- `bun run test` passes.
- `bun run tev` passes (compile, unit, Zig, the CLI suite, `test:ziggy` and the mobile suite for this platform).
- `bun run stories:ziggy` completes with no story failing.
- The `git grep` in step 10 prints nothing.
- iOS smoke tests run only on macOS and are CI-only from this machine.

## Notes

- The human chose, while this plan was written: delete `IPlatformContext`, `PlatformContextProvider`, `usePlatform` and `mockPlatform` entirely; the code goes down into the callers and into the component that hosted the provider (`App`); no documentation review stop.
- This puts Ziggy bridge calls and the desktop/phone branches in `packages/user-interface`, which the `CLAUDE.md` rule against platform-specific code there was written to prevent while there were several platforms. The human directed this change with Ziggy as the only platform. The plan does not edit `CLAUDE.md`.
- `ZiggyContext` holds the real bridge and two small pieces of state two callers share (`erudaState` for `toggleDevTools`, called from `developer-context.tsx` and `stories-page.tsx`; `exportTestState`, set by `App` and read by `saveDownloadedFiles`). It is needed so stories can swap in a `FakeZiggy`; reading `window.ziggy` directly would leave stories no way to fake the core.
- Page-only events (`database-chosen`, `background-work-settings-changed`, `database-content-changed`, and `database-opened`/`database-closed`/`platform-event`/`show-notification` when the page starts them) go through `AppMessages.emit`, replacing the provider's callback sets and `autoImportChangedRef`. `database-chosen` is separate from `database-opened` because the provider recorded the sync database only for `notifyDatabaseOpened`, not for the core's own `database-opened` event.
- The provider was mounted once per route, so leaving `/stories` remounted it and resent `page-loaded`. With the work in `App` it runs once per page load.
- Each `onTaskMessage`/`onTaskComplete` caller now registers its own bridge listener, each inside its own `flushSync`, where the provider had one listener calling every handler inside one `flushSync`. `ZiggyQueueBackend` already listens on the same bridge events the same way.
- `menu-actions.ts`, `background-work.ts`, `mobile-settings.ts`, `seeded-news.ts`, `ziggy-test-transport.ts`, `renderer-log.ts` and the queue backend stay in `apps/photosphere-frontend`, because only `App` and `main.tsx` use them.
- An older, larger plan for the same goal exists at `docs/plans/new/plan-remove-platform-provider-ziggy.md`. This plan replaces it and does not depend on it.
- No Release step: nothing external was asked for.
