# Merge Electron Smoke Tests into the Shared Mobile Harness

## Overview

The mobile smoke tests drive the app from the host over a WebSocket: a host-side control bridge (`apps/smoke-tests/lib/control-bridge.ts`) exposes the HTTP command surface, relays each command to the app's WebView over a WebSocket, and the shared DOM driver (`packages/user-interface/src/lib/test-driver.ts` + `test-driver-ws.ts`) executes it. Electron still uses the older model: an in-process HTTP server (`apps/desktop/src/lib/test-control-server.ts`) compiled into the app, driven over Electron IPC.

This plan converts Electron to the same host-bridge model and folds the desktop suite into the shared `apps/smoke-tests` harness so there is one suite, one driver, and one runner for all shells. Electron becomes `PLATFORM=electron` alongside `android` and `ios`. The in-process `TestControlServer` is retired. `bun run test:electron` keeps working and stays in `test:all`.

Payoff:

- No test-only HTTP control server inside the shipped Electron app (a security win).
- A single set of test bodies instead of desktop/mobile duplication.
- The bridge/driver proven across desktop + mobile (and ready for any future shell).

| | Electron (`main` / today) | Mobile (`origin/mobile`) |
|--|---------------------------|--------------------------|
| Suite location | `apps/desktop/smoke-tests/<n>-*/test.sh` | `apps/smoke-tests/tests/<n>-*/test.sh` |
| Control plane | In-process HTTP server in Electron main (`test-control-server.ts`) + IPC | Host Bun control bridge + WebSocket into the WebView |
| Shared DOM driver | Renderer IPC transport in `desktop-frontend` | `packages/user-interface` `test-driver.ts` + `test-driver-ws.ts` |
| Runner | `apps/desktop/smoke-tests.sh` (parallel batches of 2, `.sequential` markers, `--binary`, single-test selection) | `apps/smoke-tests/run.sh` (sequential only, android/ios) |
| In `test:all` | Yes (headless) | No (needs emulator/simulator) |

This document is the single plan of record. It folds in and replaces `docs/plans/new/plan-electron-host-bridge-smoke-tests.md` (the earlier host-bridge draft on `origin/mobile`). That draft's bridge/driver steps and constraints are kept below; this plan corrects outdated seeding assumptions (mobile already seeds), and adds two-app LAN tests, parallel runner behaviour, platform skip markers, and migration of every script that still sources the desktop `common.sh`.

## Issues

<!-- Populated later by plan:check -->

## Prerequisite

Implementation targets the mobile branch tree (`apps/smoke-tests`, shared `test-driver*`, Capacitor frontends). Do this work on a branch based on `origin/mobile` (or on `main` only after mobile has merged). The plan document itself can land on `main`; the code steps cannot.

When that implementation branch is cut from `origin/mobile`, delete `docs/plans/new/plan-electron-host-bridge-smoke-tests.md` immediately (content already folded here; a pointer lives under `docs/plans/done/`).

## Goals

1. One test body per scenario under `apps/smoke-tests/tests/`, runnable as `PLATFORM=electron|android|ios`.
2. Electron uses the host control bridge + WebSocket driver (same path as mobile), not an in-app HTTP server.
3. No test-only HTTP server remains in the shipped Electron app.
4. Preserve Electron behaviour that `test:all` relies on: headless launch, parallel batches, `.sequential` for two-app tests, single-test selection, parity of pass/fail with today's desktop suite.
5. Keep Node-only capabilities (`capturePage`, `app.quit`, worker-pool task ops) in the Electron main process; only re-expose them to the renderer over IPC. Do not re-home them without explicit approval.
6. Repoint every consumer of `apps/desktop/smoke-tests/lib/common.sh` at the shared harness before deleting the old tree.

## Non-goals

- Putting `test:and` / `test:ios` into `test:all` (still need devices).
- Making every mobile-only scenario pass on Electron, or every Electron host-FS assertion pass on mobile.
- Rewriting the CLI smoke suites or the CLI↔Desktop LAN share suite's product behaviour (only its harness import path changes).
- Replacing shell tests with Playwright or another framework.

## Current inventory

### Shared / overlapping scenarios (same number + name)

`1-load-fixture`, `2-create-database`, `3-open-database`, `4-import-photos`, `5-add-secret`, `6-add-database-entry`, `7-share-secret`, `8-share-database`, `9-view-secret`, `10-view-database`, `11-edit-encryption-key`, `12-edit-api-key`, `13-edit-s3-credentials`, `14-rename-secret`, `15-duplicate-name`, `16-remove-recent-database`, `17-news-notifications`, `17-replicate-database`, `18-move-file`, `19-download-single-asset`, `20-download-multiple-assets`, `22-edit-database-origin`.

### Electron-stronger today

- `7-share-secret` / `8-share-database`: full two-app sender+receiver round-trip (marked `.sequential`).
- Host filesystem assertions (vault JSON, `databases.toml`, replica files, download folder contents, `.db/config.json`).

### Mobile-only today

- `0-launch-and-navigate` (bridge/driver smoke).
- `9-share-roundtrip` (loopback LAN via `/lan-share-roundtrip`).
- `21-import-video` (native ffmpeg path).
- `28-host-emulator-comms` (adb/emulator networking).

### External consumers of the desktop harness (must migrate before delete)

- `scripts/story-player.sh` (Electron path sources desktop `common.sh`; android/ios already use shared).
- `apps/desktop/cycle-stories-smoke-test.sh` (legacy; mobile uses `story-player.sh`).
- `apps/desktop/screenshots/capture-ux.sh`.
- `cli-desktop-lan-share-smoke-tests.sh`.

## Architecture after merge

```text
test.sh
  --HTTP-->  control-bridge (Bun on host, apps/smoke-tests)
                 | WebSocket
                 v
            App renderer (shared test-driver + test-driver-ws)
                 |
                 +-- Electron: platformHandlers -> IPC -> main (capturePage, quit)
                 +-- Android/iOS: screenshot/quit stay host-side (adb / simctl)
```

Launch differences stay in `lib/electron.sh` / `android.sh` / `ios.sh`. Test bodies call only `common.sh` helpers. The bridge host for Electron is `localhost` with no port forwarding.

## Constraints

- **No re-homing without explicit approval.** Do not move, relocate, or change where any Node-only / main-process capability runs, specifically the window screenshot (`capturePage`), app quit (`app.quit`), and worker-pool task operations, without the user's explicit approval first. These must stay in the Electron main process unless the user approves otherwise.
- The intended design keeps those capabilities in the main process and only re-exposes them to the renderer over IPC (steps 3 and 6); it does not move the logic out of main. If any step would actually relocate one of these capabilities, stop and get approval before implementing it.
- This constraint overrides any step below: if executing a step appears to require re-homing a capability, pause and ask rather than proceed.
- Prefer small, focused edits. Do not reformat whole files.
- Every new/changed branch in TypeScript gets a unit test (see Unit Tests).
- Never invoke `.sh` scripts directly from docs or CI instructions; use `bun run` script names from root `package.json`.
- Do not manually `rm -rf` a smoke test's `tmp/` outside the runner (the runner already cleans it).

## Steps

### Phase A — Driver and Electron adopt the host bridge

1. **Extend the shared driver with platform-specific command handlers.**
   In `packages/user-interface/src/lib/test-driver.ts`, change `installTestDriver(transport: ITestTransport)` to `installTestDriver(transport: ITestTransport, platformHandlers?: ITestPlatformHandlers)`.
   Define a named interface `ITestPlatformHandlers` mapping a command name to an async handler returning `string | undefined` (used for `screenshot` and `quit`, which need shell-native capability).
   In the command switch, before the `default` throw, consult `platformHandlers[command]` and call it if present.
   Keep all existing DOM cases unchanged.
   Requirement: package type-checks; unit tests in step 19 pass.

2. **Thread platform handlers through the WebSocket client.**
   In `packages/user-interface/src/lib/test-driver-ws.ts`, change `connectTestDriverWebSocket(url: string)` to `connectTestDriverWebSocket(url: string, platformHandlers?: ITestPlatformHandlers)` and pass them to `installTestDriver`.
   The reply path already serialises a returned `string` as `value`; a `screenshot` handler returns base64 PNG text, which the bridge writes to disk.
   Requirement: type-checks; unit tests in step 19 pass.

3. **Add main-process screenshot + quit IPC for Electron.**
   In `apps/desktop/src/main.ts`, register `ipcMain.handle('test-capture-page', ...)` that calls `mainWindow.webContents.capturePage()` and returns the PNG as a base64 string, and `ipcMain.on('test-quit', () => app.quit())`.
   In `apps/desktop/src/preload.ts`, expose `capturePage(): Promise<string>` (invoke `test-capture-page`) and `quit(): void` (send `test-quit`) on `electronAPI`.
   In `apps/desktop-frontend/src/lib/electron-ipc.ts`, add `capturePage` and `quit` to `IElectronAPI`.
   Requirement: desktop + desktop-frontend type-check.

4. **Wire test window events on the Electron platform provider.**
   In `apps/desktop-frontend/src/lib/platform-provider-electron.tsx`, add a `useEffect` that listens for `TEST_MENU_EVENT` and `TEST_OPEN_DATABASE_EVENT` (imported from `user-interface`) and fires the existing `menuActionCallbacksRef` and `openedCallbacksRef` respectively, mirroring `PlatformProviderMobile`.
   This lets the shared driver's `doMenu` / `doOpenDatabase` drive Electron without the in-process server.
   Leave the existing IPC `menu-action` / `navigate` / `database-opened` listeners in place (real app menu still uses them).
   Requirement: exercised by create/open-database e2e scenarios (step 21); component is not unit tested.

5. **Switch the Electron renderer to the WebSocket client.**
   In `apps/desktop-frontend/src/index.tsx`, in the `isTestMode` block, replace the Electron-IPC `ITestTransport` + `installTestDriver` call with `connectTestDriverWebSocket(\`ws://localhost:${bridgePort}\`, platformHandlers)`, where `bridgePort` is read from a new `testBridgePort` URL query parameter and `platformHandlers` is `{ screenshot: async () => electronAPI.capturePage(), quit: async () => { electronAPI.quit(); return undefined; } }`.
   Remove the now-unused IPC transport.
   Keep the existing renderer console patch or rely on the WS client's `patchConsole`; pick one and remove the duplicate.
   Requirement: desktop-frontend type-checks; e2e suite (step 21) passes.

6. **Pass the bridge port to the renderer and stop creating the in-process server.**
   In `apps/desktop/src/main.ts`: when `testMode` is set, append `&testBridgePort=${process.env.PHOTOSPHERE_TEST_PORT}` to the loaded `fileUrl` (the harness sets `PHOTOSPHERE_TEST_PORT` to the bridge port).
   Delete the `TestControlServer` import, the `testControlServer` variable, its construction, and the `testControlServer.notifyReady()` call.
   Readiness is now signalled by the renderer sending `ready` over the WebSocket.
   Requirement: desktop type-checks; e2e suite passes.

7. **Teach the control bridge `electron` screenshot and quit.**
   In `apps/smoke-tests/lib/control-bridge.ts`:
   - In `handleScreenshot`, add an `electron` branch that forwards a `screenshot` command to the app over the WebSocket (via `sendCommand`) and writes the returned base64 `value` to `outputPath` (decode base64 → bytes).
   - In `handleQuit`, add an `electron` branch that forwards a `quit` command to the app.
   Keep the existing `android` / `ios` host-side branches.
   Requirement: package type-checks; unit tests in step 20 pass.

### Phase B — Shared harness grows an Electron platform

8. **Add `apps/smoke-tests/lib/electron.sh`.**
   Create the Electron platform launcher with the same lifecycle surface as android/ios:
   - `electron_setup_env` — no-op or resolve the electron binary.
   - `electron_prepare` — verify the electron binary / `xvfb-run` availability on Linux.
   - `electron_build` — bundle desktop-frontend + desktop the same way `apps/desktop/smoke-tests.sh` does today (`bun run bundle` in each; must reproduce `bundle_app` or Electron will launch stale code).
   - `electron_install` — no-op.
   - `electron_launch <port> [x_pos]` — launch with `PHOTOSPHERE_TEST_MODE=1`, `PHOTOSPHERE_TEST_PORT=<port>` (bridge port), isolated `PHOTOSPHERE_CONFIG_DIR` / `PHOTOSPHERE_VAULT_DIR` / `PHOTOSPHERE_LOG_DIR` under the test tmp dir, `PHOTOSPHERE_VAULT_TYPE=plaintext`, `NODE_ENV=testing`, optional `PHOTOSPHERE_NEWS_URL` / picker stubs (the same env the desktop `start_app` sets today). Headless via `xvfb-run -a` on Linux unless `SHOW_UI=1`. Window geometry `960x800+X+0` (default X=0; second app uses 960). Write pid to `$tmp_dir/app.pid`.
   - `electron_stop <port>` — kill the pid from `$tmp_dir/app.pid` (idempotent).
   - `electron_seed_database <host_fixture_dir> <dest_name>` — copy/link fixture onto the host path the Electron app will open (host FS, not device sandbox).
   - `electron_reset_path` / `electron_cleanup` as needed for parity with mobile helpers.
   Optional later: `USE_BINARY=true` path that launches the packaged release binary (preserve today's `--binary` behaviour if cheap; otherwise defer with a note in Notes).
   In `apps/smoke-tests/lib/common.sh`, extend `load_platform` to source `electron.sh` when `PLATFORM=electron`.
   The bridge host for Electron is `localhost` with no port forwarding.
   Requirement: `bash -n` clean on all touched shell files.

9. **Make `start_app` / `stop_app` honour pid-managed (Electron) vs device-managed (mobile) apps.**
   In `apps/smoke-tests/lib/common.sh`, ensure `start_app` starts the bridge, then calls `${PLATFORM}_launch`; for Electron the launched process pid is recorded by `electron_launch`.
   Ensure `stop_app` calls `${PLATFORM}_stop` and then kills the bridge, and that Electron's `/quit` (forwarded to the app) plus `electron_stop` are both safe/idempotent.
   Requirement: `bash -n` passes.

10. **Support multiple concurrent apps (two bridges) for Electron LAN tests.**
    Desktop `7-share-secret` / `8-share-database` start two Electron processes with two control ports. The shared `start_app` today starts one bridge per tmp dir.
    Keep that model: each tmp dir (`…/sender`, `…/receiver`) gets its own bridge + launch. Do not require a multi-client single bridge.
    Ensure `start_app` / `stop_app` take a tmp dir (already do) and that `electron_launch` reads config/vault/log dirs from that tmp dir.
    Thread the optional window X offset through to `electron_launch` so the receiver can sit at `+960`.
    Requirement: `bash -n` clean; covered by step 21 two-app scenarios.

11. **Unify seeding helpers without weakening mobile.**
    Mobile already seeds via `${PLATFORM}_seed_database` (adb/simctl) and bridge commands (`seed-databases`, `seed-secrets`, `seed-recent`, `seed-news`, `reset-config`). Electron seeds by writing host vault/config/CLI-init paths.
    In `apps/smoke-tests/lib/common.sh` (or a new `lib/seed.sh` sourced by it), define helpers the test bodies call instead of inline host seeding:
    - `seed_database <fixture_host_path> <name>` → `${PLATFORM}_seed_database …`
    - `seed_secret` / `seed_databases_config` (or equivalent) for Electron host vault JSON and `databases.toml` where the bridge seed commands are not the Electron path
    Implement them per platform in `electron.sh` / `android.sh` / `ios.sh`. Electron provides real host-FS implementations (CLI `init`, write vault JSON, write `databases.toml`, exactly as the current desktop tests do). Mobile keeps its existing adb/simctl / bridge seed path; do **not** stub mobile seeding as "not available".
    Where Electron needs host-FS setup the bridge cannot do, keep that in the Electron launcher helpers or behind `if [ "$PLATFORM" = "electron" ]` blocks inside the shared test body.
    Requirement: existing mobile tests keep working unchanged after any rename to wrappers; `bash -n` passes.

12. **Upgrade `run.sh` for Electron runner features.**
    Extend `apps/smoke-tests/run.sh` so that when `PLATFORM=electron` (or via flags):
    - Default parallel batches of 2 for tests without a `.sequential` marker; `.sequential` tests run alone (needed for two-app LAN).
    - `--sequential` and `--parallel [N]` flags matching today's desktop runner.
    - Single-test selection by number or fuzzy name (`bun run test:electron -- 4` / `import`).
    - Per-test timeout (120s) and log capture under `<test>/tmp/test-run.log`.
    - Wipe `<test>/tmp` before each run (already).
    Android/ios can stay sequential-only (device contention); do not force parallel on mobile.
    Update the `PLATFORM` check to allow `electron`.
    Requirement: `bash -n` clean; step 21 exercises parallel + sequential paths.

13. **Add platform allow/skip markers.**
    Introduce an optional per-test file (e.g. `.platforms`) listing allowed platforms, or `.skip-<platform>` markers.
    Defaults: a test with no marker runs on all platforms.
    Mark mobile-only tests so Electron skips them: `28-host-emulator-comms`, and any scenario that cannot run without a device (`9-share-roundtrip` may run on Electron if `/lan-share-roundtrip` works there; if not, skip on electron).
    Mark Electron-only full round-trips if a shared body needs a reduced mobile variant: prefer one body with `if [ "$PLATFORM" = "electron" ]` for the receiver half rather than two copies.
    Requirement: runner prints `SKIP` for excluded platforms; exit code remains success when all non-skipped tests pass.

### Phase C — Merge test bodies and retire the desktop harness

14. **Merge each overlapping scenario into one shared body.**
    For every scenario under `apps/desktop/smoke-tests/<n>-<name>/test.sh`, update the corresponding `apps/smoke-tests/tests/<n>-<name>/test.sh` to be the single shared body:
    - Source `../../lib/common.sh`.
    - Use `start_app` / `wait_for_ready` / `send_command` / `wait_for_log` / `check_no_errors` / `stop_app`.
    - Use the `seed_*` helpers (step 11) for setup.
    - Drive the app with `send_command` exactly as today; prefer real UI flows (menu → dialog → confirm, drag-drop) over dropped `/create-database` / `/import-assets` shortcuts so Electron and mobile exercise the renderer worker-pool path.
    - Guard host-filesystem assertions behind `if [ "$PLATFORM" = "electron" ]` (electron can verify host files; mobile cannot). Restore the assertions that were dropped in the mobile-only port where Electron can still check files.
    - For `7-share-secret` and `8-share-database`: on Electron run the full two-app flow (`.sequential`); on mobile keep the sender-only (or round-trip helper) behaviour already on the mobile branch.
    - Keep `0-launch-and-navigate` as a mobile/electron-agnostic smoke unless it is android-specific.
    Confirm during this step that no migrated test relies on a dropped `TestControlServer` endpoint (`/create-database`, `/import-assets`, `/data`); if one does, drive it through the UI instead. Only `open-database` is kept as a driver command (window event).
    Requirement: shell files `bash -n` clean; suite runs (steps 21–22).

15. **Repoint root scripts.**
    In root `package.json`:
    - `test:electron` → `cd ./apps/smoke-tests && PLATFORM=electron ./run.sh`
    - `test:electron:seq` → same with `--sequential`
    - Keep `test:and` / `test:ios` as they are.
    - Keep `test:electron` inside `test:all` and `smoke` (Electron is headless; mobile suites stay out of `test:all`).
    Point `stories` / Electron path of `scripts/story-player.sh` at the shared `common.sh` + `PLATFORM=electron` (stop sourcing `apps/desktop/smoke-tests/lib/common.sh`).
    Requirement: script names unchanged for callers; `grep` shows no remaining references to the old paths from package scripts.

16. **Migrate remaining desktop-harness consumers.**
    - Update `cli-desktop-lan-share-smoke-tests.sh` to source `apps/smoke-tests/lib/common.sh` with `PLATFORM=electron` (or a thin wrapper that sets it).
    - Update `apps/desktop/screenshots/capture-ux.sh` similarly.
    - Delete or thin-wrap `apps/desktop/cycle-stories-smoke-test.sh` to call `scripts/story-player.sh --platform electron` so there is one stories cycler.
    Requirement: `grep -rn "desktop/smoke-tests" --include='*.sh' --include='*.md' --include='package.json'` shows no remaining runtime references (docs/plans history excluded).

17. **Retire the in-process server and old desktop suite.**
    Once parity is confirmed (step 21), delete:
    - `apps/desktop/src/lib/test-control-server.ts` and its unit test file.
    - `apps/desktop/smoke-tests/` (all numbered dirs + `lib/`).
    - `apps/desktop/smoke-tests.sh`.
    Requirement: repo compiles; `grep -rn "TestControlServer" apps packages` returns nothing; no remaining references to the old paths.

18. **Remove the superseded draft plan file on the mobile tree.**
    Delete `docs/plans/new/plan-electron-host-bridge-smoke-tests.md` if it is still present on the implementation branch (content is fully folded into this file; see `docs/plans/done/plan-electron-host-bridge-smoke-tests.md`).

### Phase D — Automated verification

19. **Unit-test driver platform handlers.**
    Update `packages/user-interface/src/test/lib/test-driver.test.ts` (and WS tests if present) to cover `installTestDriver` with `platformHandlers`:
    - a provided `screenshot` handler is invoked and its value returned;
    - a provided `quit` handler is invoked;
    - an unknown command with no platform handler still throws `"not implemented"`.
    Also cover `connectTestDriverWebSocket`: when constructed with `platformHandlers`, a received `screenshot` command resolves to a reply whose `value` is the handler's return; existing command/reply/log/ready tests still pass.
    Requirement: `bun run test -- test-driver` passes.

20. **Unit-test bridge electron branches.**
    Update `apps/smoke-tests/src/test/control-bridge.test.ts` using the existing fake-WebSocket-client test harness:
    - with `platform: 'electron'`, `/screenshot` forwards a `screenshot` command and writes the decoded base64 reply to `outputPath`;
    - with `platform: 'electron'`, `/quit` forwards a `quit` command;
    - existing android/ios and forwarding tests unchanged.
    Requirement: smoke-tests package tests pass.

21. **Electron suite parity.**
    Ensure `bun run test:electron` (shared harness, `PLATFORM=electron`) runs `apps/smoke-tests/tests/*` headlessly (xvfb on Linux) and passes for every scenario that passed under the old desktop harness.
    Include at least one scenario that calls `/screenshot` (verifies the app-returned base64 image is written) and one that calls `/quit`.
    Confirm `.sequential` two-app tests still pass and parallel batches do not flake them.
    The Electron platform-provider window-event path (`TEST_MENU_EVENT` / `TEST_OPEN_DATABASE_EVENT`) is exercised by the create/open-database scenarios under electron.
    Requirement: full electron suite green; pass set matches pre-migration desktop suite for overlapping scenarios.

22. **Mobile non-regression.**
    Re-run `bun run test:and` (and `bun run test:ios` where the environment has Xcode). Pass/fail set for previously passing mobile tests must be unchanged by the shared-suite refactor.
    Requirement: no new mobile failures attributable to this merge.

23. **Compile and full gate.**
    Run `bun run c` / `bun run compile` for the whole repo (desktop, desktop-frontend, user-interface, smoke-tests, mobile-frontend), `bun run test` for unit tests (including updated `test-driver`, `test-driver-ws`, and `control-bridge`), and `bun run test:all` (includes the new `test:electron`).
    Requirement: all green.

## Unit Tests

- `installTestDriver` (`test-driver.ts`): platform handler for `screenshot` is invoked and its return value is propagated; platform handler for `quit` is invoked; unknown command without a platform handler throws `"not implemented"`.
- `connectTestDriverWebSocket` (`test-driver-ws.ts`): when constructed with `platformHandlers`, a received `screenshot` command resolves to a reply whose `value` is the handler's return; existing command/reply/log/ready tests still pass.
- `ControlBridge` (`control-bridge.ts`): `platform: 'electron'` `/screenshot` forwards a `screenshot` command and writes the decoded base64 reply to `outputPath`; `platform: 'electron'` `/quit` forwards a `quit` command; existing android/ios and forwarding tests unchanged.
- Main-process `test-capture-page` / `test-quit` handlers: not unit tested directly (Electron main); covered by the electron e2e screenshot/quit steps instead.

## Smoke Tests

- `apps/smoke-tests/tests/*` run with `PLATFORM=electron` headlessly (xvfb on Linux): every migrated desktop scenario passes, including a scenario that calls `/screenshot` and one that calls `/quit`.
- Two-app `.sequential` tests `7-share-secret` and `8-share-database` on electron.
- The same `tests/*` run with `PLATFORM=android` on an emulator: pass/fail set unchanged from before this plan.
- Electron platform-provider window-event path (`TEST_MENU_EVENT` / `TEST_OPEN_DATABASE_EVENT`) is exercised by the create/open-database scenarios under electron (these contexts are not unit tested).
- `scripts/story-player.sh --platform electron` still completes a stories cycle after the harness repoint.

## Verify

- `bun run compile` / `bun run c` passes for all packages (desktop, desktop-frontend, user-interface, smoke-tests, mobile-frontend).
- `bun run test` passes, including the updated `test-driver`, `test-driver-ws`, and `control-bridge` unit tests.
- `bun run test:electron` (shared harness, `PLATFORM=electron`) runs the full `apps/smoke-tests/tests` suite headlessly and every scenario that passed under the old desktop harness passes now (parity).
- `bun run test:and` shows an unchanged pass/fail set.
- `grep -rn "TestControlServer" apps packages` returns nothing; `apps/desktop/smoke-tests` and `apps/desktop/smoke-tests.sh` no longer exist.
- No runtime script still sources `apps/desktop/smoke-tests/lib/common.sh`.
- `bun run test:all` passes (`test:electron` remains wired in; mobile suites stay out).
- `docs/plans/new/plan-electron-host-bridge-smoke-tests.md` is absent on the implementation branch.

## Notes

- Screenshot is handled in-app for Electron (renderer asks main to `capturePage`, returns base64, bridge writes it) rather than host-side OS capture, because `capturePage` is reliable and window-targeted whereas host capture of an xvfb window is fragile. This is why the driver gains a `platformHandlers` hook instead of pushing screenshot entirely host-side.
- Security win after Phase C: there is no test-only HTTP server compiled into or runnable inside the shipped Electron app; the only test affordance is the renderer opening an outbound WebSocket when `testMode` + `testBridgePort` are present.
- Quit: forwarded to the app for Electron (renderer → `test-quit` IPC → `app.quit()`); the harness `electron_stop` still kills the pid as a backstop. For mobile, quit stays host-side.
- The `/create-database`, `/import-assets`, `/open-database`, `/data` endpoints on the old `TestControlServer` are not all needed: the migrated tests create/import via the real UI (menu → dialog → confirm, drag-drop), which exercises the renderer worker-pool path. Only `open-database` is kept as a driver command (window event). Confirm during step 14 that no migrated test relies on a dropped endpoint; if one does, drive it through the UI instead.
- Seeding is the key to a single suite: electron seeds the host filesystem (as today); mobile uses its existing device/bridge seed path. Same shared bodies, platform-specific seed implementations — no per-platform test copies. (The earlier draft's "stub mobile seeding until storage lands" approach is obsolete; mobile already seeds.)
- `test:electron` stays in `test:all` because the Electron suite runs headless; the mobile suites stay out of `test:all` (need an emulator/simulator).
- Numbering quirks (two `17-*` dirs, mobile `9-share-roundtrip` alongside `9-view-secret`) can stay as-is for this merge; renumbering is a separate cleanup.
- Risk: `bun run test:electron` currently bundles via `apps/desktop/smoke-tests.sh`'s `bundle_app`; `electron.sh` must reproduce that bundling (main + renderer) before launch, or the harness must call the existing bundle scripts.
- Risk: parallel electron runs need unique tmp dirs, ports, and config/vault dirs per test (already true per-test tmp); two-app tests must remain `.sequential`.
- `--binary` packaged-app mode is nice-to-have; implement in `electron_launch` if the old path is a straight port, otherwise leave a follow-up note rather than blocking the merge.
