# Sync gating: Wi-Fi-only, offline-skip, and a master enable/disable toggle

## Overview
Photosphere currently syncs automatically with no user control: an edit-driven debounce and a 5-minute periodic timer in each host (desktop `main.ts`, dev-server `index.ts`) enqueue the shared `sync-database` task whenever a database has an `origin`. There is no way to disable syncing, no Wi-Fi/cellular awareness, and offline is only handled reactively (the worker tries and fails when the origin storage is unreachable). This plan adds two persisted user settings on the Configuration page: a master "Enable syncing" toggle and an "Only sync over Wi-Fi" toggle (both default on), plus offline-skip. All policy is computed in a new shared `SyncContext` in `packages/user-interface` and pushed to each host scheduler as a single `syncAllowed` boolean, so the platform rule is honoured (no platform-specific code in the shared UI) and every host obeys one gate. Network detection is abstracted behind the existing platform interface: desktop/web derive online/offline from the standard `navigator.onLine` and report connection type `"unknown"` (treated as allowed), while mobile keeps a stub connection type now with a clearly marked slot for `@capacitor/network` later (mobile has no sync scheduler yet, so its gate is not yet exercised end-to-end).

## Issues
<!-- Leave empty — populated later by plan:check -->

## Design decisions (defaults chosen; revisit if needed)
- Toggles live on the general Configuration page (`configuration.tsx`), per the request "toggle in configuration".
- The gate is computed once in shared UI and pushed to hosts as a single boolean. Hosts do not read the toggles or detect the network themselves. This avoids duplicating network detection across three host environments and keeps all policy in one place.
- `connectionType` is `"wifi" | "cellular" | "none" | "unknown"`. "Only sync over Wi-Fi" blocks only `"cellular"`; `"wifi"` and `"unknown"` are allowed. So on desktop/web (which cannot distinguish wired/wifi/metered) the toggle effectively means "sync whenever online".
- Mobile network-type detection via `@capacitor/network` is deferred. Mobile reports `"unknown"` for now, with a marked insertion point. Mobile also has no sync scheduler yet (pre-existing gap), so its `setSyncAllowed` is a stored no-op.
- Defaults: `syncEnabled = true`, `syncOnlyOnWifi = true`. Hosts default `syncAllowed = false` until the renderer pushes the computed value on mount (the renderer always mounts on startup, so the gap is momentary and periodic/debounced sync tolerates it).
- The CLI `psi sync` command (`apps/cli/src/cmd/sync.ts`) is a manual, explicit action and is intentionally NOT gated.

## Steps

1. **Add the pure sync-gate function and network types.**
   - Create `packages/user-interface/src/lib/sync-gate.ts`.
   - Export type alias `NetworkConnectionType = "wifi" | "cellular" | "none" | "unknown";` with a `//` comment.
   - Export interface `ISyncGateInputs` (fields, each with a `//` comment): `syncEnabled: boolean`, `syncOnlyOnWifi: boolean`, `connected: boolean`, `connectionType: NetworkConnectionType`.
   - Export function `computeSyncAllowed(inputs: ISyncGateInputs): boolean` with a `//` comment block. Logic: return `false` if `!syncEnabled`; return `false` if `!connected`; return `false` if `connectionType === "none"`; return `false` if `syncOnlyOnWifi && connectionType === "cellular"`; otherwise `true`.
   - Requirement: `bun run compile` succeeds; the new unit test (see Unit Tests) passes.

2. **Extend the platform interface with network + sync-gate methods.**
   - In `packages/user-interface/src/context/platform-context.tsx`, add interface `INetworkStatus` with fields `connected: boolean` and `connectionType: NetworkConnectionType` (import the type alias from `../lib/sync-gate`), each with a `//` comment.
   - Add three methods to `IPlatform` (each with a `//` doc comment): `getNetworkStatus(): Promise<INetworkStatus>`, `onNetworkStatusChange(callback: (status: INetworkStatus) => void): () => void` (returns an unsubscribe function), and `setSyncAllowed(allowed: boolean): void` (pushes the computed gate to the host scheduler).
   - Do NOT add default implementations here; each platform provider implements them (steps 3-5). Do not touch the existing `IPlatformEvent` bus (network detection lives in the webview, not the host, so the bus is not needed).
   - Requirement: `bun run compile` succeeds after the provider implementations in steps 3-5 exist (compile is expected to fail between step 2 and step 5 because the providers do not yet implement the new methods; treat the group 2-5 as landing together, then compile clean).

3. **Implement the new methods in the web provider.**
   - In `apps/dev-frontend/src/lib/platform-provider-web.tsx`:
     - `getNetworkStatus`: return `{ connected: navigator.onLine, connectionType: "unknown" }`.
     - `onNetworkStatusChange`: add `window` `"online"`/`"offline"` listeners that call the callback with the derived `INetworkStatus`; return an unsubscribe that removes both listeners.
     - `setSyncAllowed`: send a WebSocket message `{ type: "set-sync-allowed", allowed }` using the existing `send`/`sendAndWait` mechanism used for `notify-database-edited`.
   - Requirement: covered by compile once steps 2-5 all land.

4. **Implement the new methods in the desktop (Electron) provider.**
   - In `apps/desktop-frontend/src/lib/platform-provider-electron.tsx`:
     - `getNetworkStatus`: return `{ connected: navigator.onLine, connectionType: "unknown" }`.
     - `onNetworkStatusChange`: same `window` online/offline pattern as web.
     - `setSyncAllowed`: dispatch through the existing generic `main-command` channel with a named action, e.g. `electronAPI.invoke("main-command", { command: "set-sync-allowed", allowed })`, mirroring how `toggleDevTools` uses `main-command`. Do NOT add a new IPC channel.
   - Requirement: covered by compile once steps 2-5 all land.

5. **Implement the new methods in the mobile provider (deferred plugin).**
   - In `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx`:
     - `getNetworkStatus`: return `{ connected: navigator.onLine, connectionType: "unknown" }`. Add a `//` comment marking this as the insertion point for `@capacitor/network` `Network.getStatus()` (which returns real `connected` + `connectionType`).
     - `onNetworkStatusChange`: `window` online/offline pattern, with a `//` comment noting the future `Network.addListener("networkStatusChange", ...)` wiring.
     - `setSyncAllowed`: store the latest value in a module field and no-op otherwise, with a `//` comment that mobile has no sync scheduler yet so the value is retained for a future mobile scheduler.
   - Requirement: `bun run compile` now succeeds for the whole workspace (steps 2-5 complete).

6. **Create the shared SyncContext.**
   - Create `packages/user-interface/src/context/sync-context.tsx`, following the pattern in `packages/user-interface/src/context/developer-context.tsx`.
   - Module-level key constants: `const SYNC_ENABLED_CONFIG_KEY = "syncEnabled";` and `const SYNC_ONLY_ON_WIFI_CONFIG_KEY = "syncOnlyOnWifi";` (each with a `//` comment).
   - Interface `ISyncContext` (each field a `//` comment): `syncEnabled: boolean`, `syncOnlyOnWifi: boolean`, `toggleSyncEnabled: () => void`, `toggleSyncOnlyOnWifi: () => void`.
   - `SyncContextProvider`:
     - `useConfig()` and `usePlatform()`.
     - State: `syncEnabled` and `syncOnlyOnWifi` via `useState<boolean>(true)` (defaults on), and `networkStatus` via `useState<INetworkStatus>` initialised from a mount fetch.
     - Load-on-mount effects: read `config.get<boolean>(KEY)` for each toggle and apply `stored ?? true`.
     - Network effect on mount: call `platform.getNetworkStatus()` to seed state, then subscribe with `platform.onNetworkStatusChange(setNetworkStatus)`; unsubscribe on unmount.
     - Toggle writers: compute `nextValue`, `setState`, and fire-and-forget `config.set<boolean>(KEY, nextValue)` (mirror `toggleShowFpsIndicator`).
     - Gate-push effect: whenever `syncEnabled`, `syncOnlyOnWifi`, or `networkStatus` changes, call `platform.setSyncAllowed(computeSyncAllowed({ syncEnabled, syncOnlyOnWifi, connected: networkStatus.connected, connectionType: networkStatus.connectionType }))`. This also runs on mount so the host receives the initial gate.
     - Export `useSync()` hook.
   - Requirement: `bun run compile` succeeds; behaviour covered by the smoke/e2e tests (contexts are not unit tested).

7. **Mount SyncContextProvider in every frontend app.**
   - In each app root that already wraps `<Main>` in `<DeveloperContextProvider>` (`apps/desktop-frontend/src/app.tsx`, `apps/dev-frontend/src/app.tsx`, `apps/android-frontend/src/app.tsx`, `apps/ios-frontend/src/app.tsx`), add `<SyncContextProvider>` inside the existing `ConfigContextProvider`/`PlatformContext` stack (it needs both config and platform). Place it alongside `DeveloperContextProvider`.
   - Requirement: `bun run compile` succeeds; e2e coverage via the smoke test.

8. **Add the two toggles to the Configuration page.**
   - In `packages/user-interface/src/pages/configuration.tsx`, import `useSync()` and render two MUI Joy `Switch` rows (mirroring the `ListItem` + `endAction` `Switch` pattern in `packages/user-interface/src/pages/developer.tsx`): "Enable syncing" bound to `syncEnabled`/`toggleSyncEnabled`, and "Only sync over Wi-Fi" bound to `syncOnlyOnWifi`/`toggleSyncOnlyOnWifi`. Add stable `data-testid` attributes on each switch (e.g. `sync-enabled-toggle`, `sync-wifi-only-toggle`) for smoke tests.
   - Requirement: `bun run compile` succeeds; e2e coverage via the smoke test.

9. **Gate the desktop host scheduler.**
   - In `apps/desktop/src/main.ts`:
     - Add module state `let syncAllowed = false;` (with a `//` comment) near `isSyncRunning` (line ~68).
     - In the `main-command` dispatcher, handle `command === "set-sync-allowed"` by setting `syncAllowed = message.allowed`; when it transitions to `true`, call `scheduleSync()` so a pending sync catches up (guarded so it does not fire when no database is open).
     - In `enqueueSyncTask()` (line ~1032), return early if `!syncAllowed` (add alongside the existing `currentDatabasePath && workerPool && !isSyncRunning` guard). Add a `//` comment explaining the gate.
   - Requirement: `bun run compile` succeeds; Electron smoke test (see Smoke Tests) passes.

10. **Gate the dev-server host scheduler.**
    - In `apps/dev-server/src/index.ts`:
      - Add `syncAllowed: boolean` (default `false`) to the per-connection `IConnectionSyncState` interface (line ~75) with a `//` comment.
      - Handle an incoming WebSocket message `type === "set-sync-allowed"` (near the `notify-database-edited` handler, line ~234) by setting that connection's `syncAllowed`; when it flips to `true`, call that connection's `scheduleSync()`.
      - In `enqueueSyncTask()` (line ~83), return early if the connection's `syncAllowed` is false. Add a `//` comment.
    - Requirement: `bun run compile` succeeds; dev/web still functions (covered by existing web smoke path if present, otherwise by compile + the Electron gate test as the representative host).

11. **Persist the two toggles in the desktop TOML config.**
    - In `packages/node-api/src/lib/desktop-config.ts`, add `syncEnabled?: boolean` and `syncOnlyOnWifi?: boolean` to `IDesktopConfig` (camelCase) and `sync_enabled?: boolean` / `sync_only_on_wifi?: boolean` to `ITomlDesktopConfig` (snake_case), each with a `//` comment, and map both directions in `tomlToDesktopConfig` and `desktopConfigToToml` (four edit sites total), following the existing `devToolsOpen`/`dev_tools_open` pair.
    - Web and mobile persist arbitrary keys already, so no change is needed there.
    - Requirement: `bun run compile` succeeds; the updated round-trip unit test (see Unit Tests) passes.

12. **Run the full verification suite** (see Verify).

## Unit Tests
- `packages/user-interface/src/test/sync-gate.test.ts` (new): exhaustively test `computeSyncAllowed`:
  - Disabled: `syncEnabled: false` returns `false` regardless of other inputs.
  - Offline: `connected: false` returns `false` even when enabled.
  - `connectionType: "none"` returns `false`.
  - Wi-Fi-only ON + `"cellular"` returns `false`.
  - Wi-Fi-only ON + `"wifi"` returns `true`.
  - Wi-Fi-only ON + `"unknown"` returns `true` (desktop/web allowed).
  - Wi-Fi-only OFF + `"cellular"` returns `true`.
  - Fully enabled + connected + `"wifi"` returns `true`.
- `packages/node-api/src/test/lib/desktop-config.test.ts` (existing): extend the round-trip test to set `syncEnabled` and `syncOnlyOnWifi`, serialise to TOML and back, and assert both survive; assert absence maps to `undefined` (so defaults are applied by the UI, not the config layer).

Note: `SyncContext`, `configuration.tsx`, and the platform provider methods are contexts/components/provider glue and are not unit tested (per repo rule). They are covered by the smoke test below. The host schedulers (`main.ts`, `index.ts`) are module-scope side-effecting scripts covered by smoke tests.

## Smoke Tests
- **Electron sync-gate e2e** (extend the existing `test:electron` suite under `apps/smoke-tests`, driving the app via the existing test-control server):
  1. Open a database that has an `origin` configured (so sync would normally run).
  2. Assert that with default settings and a reachable origin, an edit produces a `sync-started` event (baseline that gating did not break normal sync).
  3. Toggle "Enable syncing" OFF via the Configuration page control (`sync-enabled-toggle`), perform an edit, and assert NO `sync-started` event fires within a bounded wait. Toggle it back ON and assert sync resumes.
  4. Restart the app and assert the persisted "Enable syncing" value is restored (proves TOML persistence from step 11 and load-on-mount from step 6).
  5. Verify the "Only sync over Wi-Fi" toggle persists across restart the same way. (On desktop the wifi-only gate reports `"unknown"` = allowed, so it does not block sync; the persistence + push path is what is asserted here.)
- **Existing suites unchanged**: `bun run test:cli`, `bun run test:cli:encrypted`, `bun run test:cli:lan-share`, and `bun run test:electron` must still pass. The CLI `psi sync` path is ungated and unaffected.

## Verify
- `bun run compile` completes with no TypeScript errors.
- `bun run test` (unit tests) passes, including the new `sync-gate.test.ts` and the extended `desktop-config.test.ts`.
- `bun run test:electron` passes, including the new sync-gate e2e checks (disable stops sync, enable resumes, both toggles persist across restart).
- `bun run test:cli`, `bun run test:cli:encrypted`, and `bun run test:cli:lan-share` all pass.
- Manual sanity grep: `grep -rn "setSyncAllowed\|syncAllowed\|computeSyncAllowed" --include="*.ts*" apps packages | grep -v node_modules` shows the gate wired in exactly the shared context, the three providers, and the two hosts.

## Notes
- **Single source of policy.** All gating logic (enabled, offline, wifi-only) is computed by `computeSyncAllowed` in the shared UI and pushed to hosts as one boolean. Hosts never read the toggles or detect the network. This is why network detection does not need to exist in the Electron main process or dev-server.
- **Offline handling is belt-and-suspenders.** The renderer pushes `syncAllowed = false` when `navigator.onLine` is false, so the host does not enqueue. The existing `merkleTreeExists(originStorage)` check in `packages/node-api/src/lib/sync-database.worker.ts:47` remains as a backstop if the origin is unreachable despite the OS reporting online.
- **Desktop/web cannot distinguish wifi from cellular.** They report `connectionType: "unknown"`, which the gate treats as allowed. So "Only sync over Wi-Fi" only truly restricts on mobile. This matches how desktops are normally used and was the chosen default; the alternative (block desktop/web unless wifi is confirmed) would disable auto-sync on those platforms whenever the toggle is on.
- **Mobile is staged.** `@capacitor/network` is not added in this plan. The mobile provider returns `"unknown"` with clearly marked insertion points. Mobile also has no sync scheduler (`notifyDatabaseEdited` is a stub and there is no periodic timer), so `setSyncAllowed` on mobile is a stored no-op. When a mobile scheduler is added later, wiring `@capacitor/network` and honouring the stored `syncAllowed` completes the feature there.
- **IPC discipline.** Desktop uses the existing generic `main-command` channel with a named `set-sync-allowed` action, not a new IPC channel, per the repo rule. The dev-server uses a new WebSocket message type, consistent with its existing `notify-database-edited`/`get-config`/`set-config` messages (not IPC channels).
- **Host default is closed.** Hosts start with `syncAllowed = false` and only sync after the renderer pushes the computed gate on mount. This means a host with no connected frontend never auto-syncs, which is acceptable (desktop always has its renderer; the dev-server's sync state is per-connection anyway). The manual CLI `psi sync` is the escape hatch for headless sync.
- **Open question for later:** whether flipping "Enable syncing" back on should force an immediate full sync or wait for the next edit/periodic tick. This plan schedules a debounced catch-up on the false→true transition; if an immediate sync is preferred, call `enqueueSyncTask()` directly instead of `scheduleSync()`.
