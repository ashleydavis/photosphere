# Remove the Ziggy platform provider

## Overview

This plan cannot be carried out while the old apps still exist. `apps/photosphere-frontend/src/lib/platform-provider-ziggy.tsx` is one of several implementations of the shared UI's `IPlatformContext` (`packages/user-interface/src/context/platform-context.tsx`). The others belong to the Electron app (`apps/desktop-frontend/src/lib/platform-provider-electron.tsx`), the web app (`apps/dev-frontend/src/lib/platform-provider-web.tsx`) and the Capacitor apps (`packages/mobile-frontend/src/lib/platform-provider-mobile.tsx`, mounted by `apps/android-frontend` and `apps/ios-frontend`). Those apps are no longer released, but CI and the pre-commit hook still compile, unit test and smoke test them (`bun run compile` covers every workspace, `run-tests.sh` runs every package's tests, and `scripts/test-everything-parallel.sh` includes `test:electron`, `test:lan-share:cli-desktop`, `test:and` and `test:ios`). While they exist, the shared UI has no way to reach the app except through `IPlatformContext`, so nothing in the Ziggy provider can go.

From here on this plan assumes the old apps have been deleted: `apps/desktop`, `apps/desktop-frontend`, `apps/dev-frontend`, `apps/android-frontend`, `apps/ios-frontend`, `packages/mobile-frontend`, `apps/smoke-tests`, their root `package.json` scripts (`dev`, `dev:web`, `build`, `bundle:renderer`, `stories`, `stories:and`, `stories:ios`, `test:electron`, `test:and`, `test:ios`, `build:and`, `build:ios`, `run:and`, `run:ios` and the rest that name them), their targets in `what-changed.yaml` and their entries in `scripts/test-everything-parallel.sh`. With them gone, Ziggy is the only platform, and a layer that turns about fifty Ziggy channels into fifty `IPlatformContext` members is a second copy of the core's channel list that has to be kept in step for no gain. This plan dissolves the provider: the app-level work it does moves into small components in `apps/photosphere-frontend`, the shared UI reaches the core through the Ziggy bridge with typed plain functions, and `IPlatformContext`, `PlatformContextProvider`, `usePlatform` and `mockPlatform` are deleted.

## Issues

## Before you start

- Confirm every old app listed in the Overview is gone: `git ls-files apps/desktop apps/desktop-frontend apps/dev-frontend apps/android-frontend apps/ios-frontend packages/mobile-frontend apps/smoke-tests` must print nothing. If it prints anything, STOP and tell the human this plan cannot start.
- `CLAUDE.md` says `packages/user-interface` must hold no platform-specific code. This plan puts Ziggy calls in that package. Read the rule in `CLAUDE.md`. If it still forbids this, STOP and tell the human the rule has to be changed first. Do not change `CLAUDE.md` yourself.
- Check whether `apps/dev-server` and `packages/mobile-worker` are used by the Ziggy app (`git grep -n` for their package names outside the deleted apps). This was not checked when the plan was written. Report what you find; do not delete them as part of this plan.

## How the provider works today

Read this before changing anything. Line numbers are from `apps/photosphere-frontend/src/lib/platform-provider-ziggy.tsx` when the plan was written.

- `PlatformProviderZiggy` (line 94) takes the bridge (`window.ziggy`) and the `get-platform` reply (`IPlatformInfo`, line 52) and wraps the app in four providers (lines 1060-1069): uuid generator, config, state and platform.
- It is mounted twice in `apps/photosphere-frontend/src/app.tsx` (line 67 for `/stories`, line 72 for the app). `apps/photosphere-frontend/src/main.tsx:9` imports `IPlatformInfo` from it.
- Every caller of `usePlatform()` is in `packages/user-interface/src`. List them with `git grep -l usePlatform -- packages/user-interface/src`.
- What it fills `IPlatformContext` with:
  - Request wrappers (lines 545-896): most members are one `ziggy.invoke` or `ziggy.send` (databases, recents, vault secrets, S3 folders, share import, update and news marks, folder and file pickers, task cancel, sync allowed).
  - Event subscriptions (lines 323-501): one bridge listener per channel hands each event to a set of callbacks. Some events also start in the page itself: `notifyDatabaseOpened` (line 589), the close-database menu item (line 524) and the test events (line 913).
  - Desktop or phone choices from `platform.platformKind` and `platform.os`: `openDatabase`, `openFolder`, `checkTools`, `copyToClipboard`, `toggleDevTools` (a phone uses the in-page Eruda console), `saveDownloadedFiles` (a phone uses the share sheet), `getPathForFile`, `supportsDragAndDropImport`, `backgroundImportDescription`.
  - Network status: calls `readBrowserNetworkStatus` and `subscribeBrowserNetworkStatus` from `user-interface`.
  - LAN share members: taken from `useLanShareTasks()` (`packages/user-interface/src/lib/use-lan-share-tasks.ts`).
  - Config and state stores (lines 1039-1058) over `get-config`/`set-config` and `get-state`/`set-state`. The config writer also re-plans the background work when a key in `BACKGROUND_WORK_CONFIG_KEYS` changes (line 1046).
- Work it does that the UI never asks for:
  - Writes the first sync settings on a new install (line 171).
  - Starts and stops the background import and sync in the core when the settings change (lines 176-291).
  - Logs import progress (lines 296-321).
  - Handles `navigate` and `menu-action` from the core (lines 454-543).
  - Sends `page-loaded` to the core (line 900). Its effect runs after every child's effect because the provider is the outermost component, so the UI's listeners already exist.
  - Test mode: turns the test driver's window events into app callbacks and then calls `signalTestPageReady` (lines 907-944), with the same ordering need.
  - Fires `onDatabaseContentChanged` when the page becomes visible again (lines 962-973). Its only user is `packages/user-interface/src/context/asset-database-source.tsx`.

## Steps

1. Add the dependencies. In `packages/user-interface/package.json` add `"ziggy-ui"` with the same specifier `apps/photosphere-frontend/package.json` uses, and move `"eruda"` from `apps/photosphere-frontend/package.json` to `packages/user-interface/package.json` if nothing else in `apps/photosphere-frontend` imports it after step 9. Run `bun install` at the repo root. `bun run compile` passes.

2. Move the platform info type. Create `packages/user-interface/src/lib/core/platform-info.ts` with `IPlatformInfo` (moved from the provider) and two functions: `backgroundImportDescription(platform: IPlatformInfo): string` (the text of lines 97-106) and `supportsDragAndDropImport(platform: IPlatformInfo): boolean`. Export them from `packages/user-interface/src/index.ts`. Change `apps/photosphere-frontend/src/main.tsx` and `app.tsx` to import `IPlatformInfo` from `user-interface`. Unit tests for both functions. `bun run compile` and `bun run test` pass.

3. Move the data types. Move every exported type in `packages/user-interface/src/context/platform-context.tsx` except `IPlatformContext`, `PlatformContextProvider` and `usePlatform` (that is `INetworkStatus`, `Unsubscribe`, `IMenuActionEvent`, `IDevToolsStateEvent`, `IPlatformEvent`, `IS3Credentials`, `IEncryptionKeyPair`, `ISharedSecretEntry`, `IDatabaseEntry`, `IShowNotificationLink`, `IShowNotificationData`, `IUpdateAvailableData`, `IDownloadAssetItem`, `IImportSession`, `IToolStatus`, `IPickFolderOptions`, `IToolsStatus`, `ISaveDownloadResult` and any other type the file exports) into `packages/user-interface/src/lib/core/core-types.ts`, with their comments. Re-export them from `platform-context.tsx` for now so nothing else changes yet. `bun run compile` passes.

4. Add the event hub. Create `packages/user-interface/src/lib/core/core-events.ts`:
    - `ICoreEventMap`: one field per event channel, naming its payload type: `database-opened` (string), `database-closed` (void), `theme-changed`, `sync-started`, `sync-completed`, `show-notification` (`IShowNotificationData`), `databases-changed`, `update-available` (`IUpdateAvailableData`), `platform-event` (`IPlatformEvent`), `task-message` and `task-completed` (an interface with `taskId` and `message` or `result`), and `database-content-changed`, `config-changed` (the key) and `database-chosen` (the path) for events that only start in the page.
    - Class `CoreEvents`, constructed with the bridge and a `deliver: (run: () => void) => void` function. `on<K>(channel: K, callback): Unsubscribe` adds a callback and, the first time a channel is subscribed, registers one bridge listener for it with `ziggy.onMessage`. `emit<K>(channel: K, payload)` calls every callback for the channel, for events that start in the page. Bridge events are passed to callbacks through `deliver`. It never calls `ziggy.removeAllListeners`, because `ZiggyQueueBackend` also listens on `task-message` and `task-completed` and the bridge cannot remove one listener alone (`ziggy/packages/ziggy/ui/src/ziggy-bridge.ts`). Page-only channels never register a bridge listener.
    - Move `apps/photosphere-frontend/src/test/fake-ziggy.ts` to `packages/user-interface/src/stories/mocks/fake-ziggy.ts` (step 11 uses it for stories) and change the imports in `apps/photosphere-frontend/src/test`. Export `FakeZiggy` from `user-interface`.
    - Unit tests with `FakeZiggy`. `bun run compile` and `bun run test` pass.

5. Add the core context. Create `packages/user-interface/src/context/core-context.tsx` with `ICoreContext` (`ziggy: IZiggyBridge`, `platform: IPlatformInfo`, `events: CoreEvents`, `devTools: DevToolsToggle` from step 6, `exportTestState: IExportTestState` from step 7), `CoreContextProvider` and `useCore()`, which throws when no provider is mounted. No logic in it. Export from `index.ts`.

6. Add the request functions. Create plain functions in `packages/user-interface/src/lib/core/`, each taking the bridge (and `IPlatformInfo` where the old member checked the platform kind) as its first arguments and keeping the old member's behaviour and comments exactly:
    - `databases.ts`: `getDatabases`, `addDatabase`, `updateDatabase`, `setDatabaseOrigin`, `removeDatabaseEntry`, `findDatabase`, `openDatabase`, `notifyDatabaseOpened` (invokes `notify-database-opened`, then emits `database-chosen` and `database-opened` on `CoreEvents`), `notifyDatabaseClosed`, `notifyDatabaseEdited`.
    - `recents.ts`: `getRecentDatabases`, `getLastDatabase`, `removeRecentDatabaseName`.
    - `vault.ts`: `listSecrets`, `addSecret`, `updateSecret`, `deleteSecret`, `getSecretValue`.
    - `files.ts`: `pickFolder`, `pickFiles`, `openFolder`, `getPathForFile` (moves `apps/photosphere-frontend/src/lib/dropped-file-path.ts` and its test into this folder), `checkTools`, `copyToClipboard`.
    - `share.ts`: `listS3Dirs`, `importSharePayload`.
    - `marks.ts`: `markUpdateAsShown`, `markNewsAsShown`.
    - `main-commands.ts`: `cancelTasks`, `setSyncAllowed`.
    - `dev-tools.ts`: class `DevToolsToggle` holding the Eruda state now in `erudaStateRef`, with `toggle(ziggy, platform)`. It takes the Eruda calls it needs as a constructor argument so it can be unit tested without Eruda.
    - Move `apps/photosphere-frontend/src/lib/to-json-value.ts` and its test into this folder, since these functions use it.
    - Unit tests for every function with `FakeZiggy`, asserting the channel, the data sent and the value returned. `bun run compile` and `bun run test` pass.

7. Move the download saving. Move `apps/photosphere-frontend/src/lib/mobile-export.ts` and `src/test/mobile-export.test.ts` into `packages/user-interface/src/lib/core/`. Add `saveDownloadedFiles(ziggy, platform, uuidGenerator, exportTestState, items, databasePath)` to `files.ts` with the body of lines 742-774. `IExportTestState` holds `stagedOutcome: ExportTestOutcome | undefined`, read and cleared by each export as today. Unit test both the desktop and the phone path. `bun run compile` and `bun run test` pass.

8. Add the app components in `apps/photosphere-frontend/src/lib`:
    - `background-work-runner.tsx`: `BackgroundWorkRunner` with no children. It holds the effects of lines 171-174, 179-291 and 296-321 unchanged, reading `ziggy`, `platform` and `events` from `useCore()`. Where the provider called `autoImportChangedRef.current` it re-plans when `events` emits `config-changed` with a key in `BACKGROUND_WORK_CONFIG_KEYS` (which moves here), and when `database-chosen` arrives it calls `recordSyncDatabase` and then re-plans (lines 580-586). It subscribes to `task-message` for the progress log.
    - `core-event-handlers.tsx`: `CoreEventHandlers`, which renders its children and holds the `navigate` and `menu-action` listeners (lines 454-543), `page-loaded` (line 900) and the test mode effect (lines 907-944). `runMenuEffect` emits `database-closed` and `platform-event` on `events` where it called the callback sets. The test mode effect emits on `events` and writes `exportTestState.stagedOutcome`. It must be mounted as an ancestor of the whole app tree so its effects still run after every child's effect.
    - React components are not unit tested. `bun run compile` passes.

9. Rewire `apps/photosphere-frontend/src/app.tsx`. At module level create the uuid generator as the provider does (lines 26-32). In `App`, create one `CoreEvents` (with `flushSync` as `deliver` for `task-message` and `task-completed`, and a direct call for the rest, keeping the reason at lines 469-471), one `DevToolsToggle`, one `IExportTestState`, the config store (lines 1039-1050, emitting `config-changed` after each write) and the state store (lines 1052-1058). Replace both `PlatformProviderZiggy` mounts with `UuidGeneratorProvider`, `ConfigContextProvider`, `StateContextProvider`, `CoreContextProvider` and `CoreEventHandlers`, with `BackgroundWorkRunner` inside the app route only. Do not change the shared UI yet, so keep `PlatformContextProvider` mounted for this step, with a value built from the new functions, so the app works in between. `bun run compile`, `bun run test` and `bun run test:ziggy` pass.

10. Move every consumer. For each file listed by `git grep -l usePlatform -- packages/user-interface/src`, replace `usePlatform()` with `useCore()` and each member with its function from step 6 or 7, `events.on(...)` for each `on...` subscription, `useLanShareTasks()` for the LAN share members, `readBrowserNetworkStatus` and `subscribeBrowserNetworkStatus` for the network members, and the step 2 functions for `backgroundImportDescription` and `supportsDragAndDropImport`. Specific cases:
    - `packages/user-interface/src/context/asset-database-source.tsx`: replace `onDatabaseContentChanged` with its own `visibilitychange` listener, moving the comment at lines 953-961 with it.
    - `packages/user-interface/src/context/import-context.tsx`: `platform: Pick<IPlatformContext, "pickFolder" | "pickFiles">` becomes an interface with those two functions, built by the caller from `pickFolder` and `pickFiles`. Update `packages/user-interface/src/test/context/import-context.test.ts` to match without changing what it asserts.
    - `packages/user-interface/src/lib/use-lan-share-tasks.ts`: change the comment that names `IPlatformContext`.
    - Work one file at a time. `bun run compile` and `bun run test` pass after each.

11. Replace the story mock. In `packages/user-interface/src/stories/mocks/index.tsx` replace `mockPlatform()` with `mockCore(): ICoreContext`, built on `FakeZiggy` with a reply set for every channel the stories call, each reply the value `mockPlatform` returned for that member. Change every story that passes overrides to `mockPlatform` (`git grep -l mockPlatform -- packages/user-interface/src/stories`) to set the matching `FakeZiggy` reply instead. Replace `PlatformContextProvider` in the story wrapper (line 552) with `CoreContextProvider`. `bun run compile` passes and `bun run stories:ziggy -- --headless` runs every story with no error in the log.

12. Delete the old code. Delete `apps/photosphere-frontend/src/lib/platform-provider-ziggy.tsx`, the temporary `PlatformContextProvider` mount from step 9, and `packages/user-interface/src/context/platform-context.tsx`, changing every import of it to `lib/core/core-types.ts`. Remove `IPlatformContext`, `PlatformContextProvider`, `usePlatform` and `mockPlatform` from every export. `git grep -n -E "IPlatformContext|PlatformContextProvider|usePlatform|mockPlatform|PlatformProviderZiggy|platform-provider-ziggy" -- packages apps` prints nothing. `bun run compile`, `bun run test` and `bun run test:everything` pass.

13. Write the documentation:
    - `apps/photosphere-frontend/README.md`: replace the `platform-provider-ziggy.tsx` line with `background-work-runner.tsx` and `core-event-handlers.tsx`, say what each does, and remove the lines for files moved to `packages/user-interface`.
    - `docs/photosphere-on-ziggy.md:23`: the platform layer no longer implements `IPlatformContext`. Say the shared UI calls the core through `useCore()` and the functions in `packages/user-interface/src/lib/core/`, and that `apps/photosphere-frontend` keeps the queue backend and the app-level work.
    - `docs/toast-notifications.md:29`: replace `IPlatformContext.onShowNotification(callback)` with `events.on("show-notification", callback)`.
    - `packages/user-interface/src/stories/README.md`: describe `mockCore` and setting a `FakeZiggy` reply for a story, if it describes the mocks.
    - Search for anything else that names the removed symbols: `git grep -n -E "IPlatformContext|PlatformContextProvider|usePlatform|mockPlatform|PlatformProviderZiggy|platform provider" -- '*.md' ':!docs/plans'` prints nothing.

## Unit Tests

- `platform-info.test.ts`: `backgroundImportDescription` for desktop, iOS and Android. `supportsDragAndDropImport` for desktop and phone.
- `core-events.test.ts`: one bridge listener per channel however many callbacks subscribe. A bridge event reaches every callback through `deliver`. Unsubscribe stops one callback and leaves the rest. `emit` reaches the callbacks of a channel without touching the bridge. A page-only channel never registers a bridge listener. `removeAllListeners` is never called.
- `databases.test.ts`, `recents.test.ts`, `vault.test.ts`, `share.test.ts`, `marks.test.ts`, `main-commands.test.ts`: for each function, the channel and data sent and the value returned, including `null` replies turned into `undefined`. `notifyDatabaseOpened` emits `database-chosen` and `database-opened` after the invoke. `addSecret` throws when the name exists. `updateSecret` sets before it deletes, and does nothing without a value. `openDatabase` does nothing on a phone.
- `files.test.ts`: `openFolder` and `checkTools` on desktop and phone. `copyToClipboard` does nothing on a phone. `saveDownloadedFiles` sends `save-assets` on a desktop, and on a phone uses the share sheet path and clears the staged test outcome after one export.
- `dev-tools.test.ts`: desktop sends `toggle-devtools` on `main-command`. A phone starts the console once and then shows and hides it in turn.
- The existing tests moved with their files (`dropped-file-path`, `to-json-value`, `mobile-export`) pass unchanged in their new place.
- `import-context.test.ts`: updated for the new parameter type, same assertions.

## Smoke Tests

- `bun run test:ziggy` on the host: every scenario passes. This covers the components, the context and every consumer moved in step 10, none of which are unit tested.
- `bun run test:ziggy:and` on the Android emulator pool, and `bun run test:ziggy:ios` on macOS: every scenario passes. These cover the phone-only paths (share sheet saving, Eruda, background work, the reload when the app comes back on screen).
- Scenarios that depend on the moved ordering: the update and news toasts after `page-loaded`, and every scenario at all in test mode, since none can start before `signalTestPageReady`.
- `bun run stories:ziggy -- --headless`: every story renders with `mockCore`.

## Verify

- `bun run compile` passes.
- `bun run test` passes.
- `bun run test:ziggy` passes. `bun run test:ziggy:and` passes when `bun run emu:and:pool:status` exits 0.
- `bun run test:everything` passes.
- `bun run stories:ziggy -- --headless` finishes with no error in its log.
- `git grep -n -E "IPlatformContext|PlatformContextProvider|usePlatform|mockPlatform|PlatformProviderZiggy|platform-provider-ziggy" -- packages apps` prints nothing.
- `apps/photosphere-frontend/src/lib/platform-provider-ziggy.tsx` and `packages/user-interface/src/context/platform-context.tsx` do not exist.

## Notes

- A smaller alternative: keep `IPlatformContext` with one implementation and move only the app-level work (steps 8 and 9) out of the provider. The file shrinks and the shared UI and the stories stay as they are. It does not remove the provider, which is what this plan was asked for.
- Typing: today `IPlatformContext` gives every request a typed signature. The functions in step 6 keep that, and `ICoreEventMap` keeps event names and payloads typed. A story or test that sets a `FakeZiggy` reply is not type-checked against the channel, so a wrong reply shows up only when the story runs.
- Ordering is the main risk. `page-loaded` and `signalTestPageReady` must be sent after every listener in the UI exists. Today that holds because the provider is the outermost component and React runs child effects first. `CoreEventHandlers` keeps it only while it stays an ancestor of the whole app tree.
- No unit tests cover the provider today (React components are not unit tested here). The Ziggy smoke tests are what catch a broken move, so run `bun run test:ziggy` after every step that touches the app.
- The background work re-plan moves from a ref the config writer called into `config-changed` and `database-chosen` events. `recordSyncDatabase` must still run only for a page-made `notifyDatabaseOpened`, not for the core's own `database-opened` event, which is why `database-chosen` is a separate page-only channel.
