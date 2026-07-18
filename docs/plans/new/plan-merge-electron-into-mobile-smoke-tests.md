# Merge Electron Smoke Tests into the Shared Mobile Harness

## Overview

Electron and mobile already drive the same UI through the same HTTP command surface (`/ready`, `/navigate`, `/click`, `/type`, …), but they do it through two different harnesses and two mostly-duplicated suites:

| | Electron (`main` / today) | Mobile (`origin/mobile`) |
|--|---------------------------|--------------------------|
| Suite location | `apps/desktop/smoke-tests/<n>-*/test.sh` | `apps/smoke-tests/tests/<n>-*/test.sh` |
| Control plane | In-process HTTP server in Electron main (`test-control-server.ts`) + IPC | Host Bun control bridge + WebSocket into the WebView |
| Shared DOM driver | Renderer IPC transport in `desktop-frontend` | `packages/user-interface` `test-driver.ts` + `test-driver-ws.ts` |
| Runner | `apps/desktop/smoke-tests.sh` (parallel batches of 2, `.sequential` markers, `--binary`, single-test selection) | `apps/smoke-tests/run.sh` (sequential only, android/ios) |
| In `test:all` | Yes (headless) | No (needs emulator/simulator) |

This plan folds Electron into the shared `apps/smoke-tests` harness so there is one suite, one driver, and one runner for all shells. Electron becomes `PLATFORM=electron` alongside `android` and `ios`. The in-process `TestControlServer` is retired. `bun run test:electron` keeps working and stays in `test:all`.

This supersedes the earlier draft on `origin/mobile` at `docs/plans/new/plan-electron-host-bridge-smoke-tests.md`. That draft got the bridge conversion right but understated seeding (mobile already seeds), omitted two-app LAN tests, parallel runner behaviour, platform skip markers, and the other scripts that still source the desktop `common.sh`.

## Prerequisite

Implementation targets the mobile branch tree (`apps/smoke-tests`, shared `test-driver*`, Capacitor frontends). Do this work on a branch based on `origin/mobile` (or on `main` only after mobile has merged). The plan document itself can land on `main`; the code steps cannot.

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

Launch differences stay in `lib/electron.sh` / `android.sh` / `ios.sh`. Test bodies call only `common.sh` helpers.

## Constraints

- **No re-homing without approval.** `capturePage`, `app.quit`, and worker-pool task operations stay in Electron main. Steps below only add IPC + platformHandlers; they do not move that logic onto the bridge host.
- Prefer small, focused edits. Do not reformat whole files.
- Every new/changed branch in TypeScript gets a unit test (see Unit Tests).
- Never invoke `.sh` scripts directly from docs or CI instructions; use `bun run` script names from root `package.json`.
- Do not manually `rm -rf` a smoke test's `tmp/` outside the runner (the runner already cleans it).

## Steps

### Phase A — Driver and Electron adopt the host bridge

1. **Extend the shared driver with platform-specific command handlers.**
   In `packages/user-interface/src/lib/test-driver.ts`, change `installTestDriver(transport: ITestTransport)` to `installTestDriver(transport: ITestTransport, platformHandlers?: ITestPlatformHandlers)`.
   Define a named interface `ITestPlatformHandlers` mapping a command name to an async handler returning `string | undefined` (used for `screenshot` and `quit`).
   In the command switch, before the `default` throw, call `platformHandlers[command]` when present.
   Keep all existing DOM cases unchanged.
   Requirement: package type-checks; unit tests in step 18 pass.

2. **Thread platform handlers through the WebSocket client.**
   In `packages/user-interface/src/lib/test-driver-ws.ts`, change `connectTestDriverWebSocket(url: string)` to `connectTestDriverWebSocket(url: string, platformHandlers?: ITestPlatformHandlers)` and pass them to `installTestDriver`.
   The reply path already serialises a returned `string` as `value`; a `screenshot` handler returns base64 PNG text for the bridge to write.
   Requirement: type-checks; unit tests in step 18 pass.

3. **Add main-process screenshot + quit IPC for Electron.**
   In `apps/desktop/src/main.ts`, register `ipcMain.handle('test-capture-page', ...)` that calls `mainWindow.webContents.capturePage()` and returns PNG base64, and `ipcMain.on('test-quit', () => app.quit())`.
   In `apps/desktop/src/preload.ts`, expose `capturePage(): Promise<string>` and `quit(): void` on `electronAPI`.
   In `apps/desktop-frontend/src/lib/electron-ipc.ts`, add those methods to `IElectronAPI`.
   Requirement: desktop + desktop-frontend type-check.

4. **Wire test window events on the Electron platform provider.**
   In `apps/desktop-frontend/src/lib/platform-provider-electron.tsx`, add a `useEffect` that listens for `TEST_MENU_EVENT` and `TEST_OPEN_DATABASE_EVENT` (from `user-interface`) and fires the existing menu/open-database callbacks, mirroring `PlatformProviderMobile`.
   Leave the real IPC `menu-action` / `navigate` / `database-opened` listeners in place for the production menu.
   Requirement: exercised by create/open-database e2e scenarios (step 20).

5. **Switch the Electron renderer to the WebSocket client.**
   In `apps/desktop-frontend/src/index.tsx`, in the `isTestMode` block, replace the IPC `ITestTransport` + `installTestDriver` call with `connectTestDriverWebSocket(\`ws://localhost:${bridgePort}\`, platformHandlers)` where `bridgePort` comes from a new `testBridgePort` URL query param and `platformHandlers` is `{ screenshot: async () => electronAPI.capturePage(), quit: async () => { electronAPI.quit(); return undefined; } }`.
   Remove the unused IPC transport. Keep a single console-forwarding path (prefer the WS client's `patchConsole`; delete the duplicate).
   Requirement: desktop-frontend type-checks.

6. **Stop creating the in-process control server; pass the bridge port into the renderer.**
   In `apps/desktop/src/main.ts`: when `testMode` is set, append `&testBridgePort=${process.env.PHOTOSPHERE_TEST_PORT}` to the loaded `fileUrl`; delete the `TestControlServer` import, construction, and `notifyReady()` call.
   Readiness is signalled by the renderer sending `ready` over the WebSocket.
   Requirement: desktop type-checks.

7. **Teach the control bridge `electron` screenshot and quit.**
   In `apps/smoke-tests/lib/control-bridge.ts`:
   - `handleScreenshot`: for `electron`, forward `screenshot` over the WebSocket, decode the base64 `value`, write bytes to `outputPath`.
   - `handleQuit`: for `electron`, forward `quit` over the WebSocket.
   Keep existing android/ios host-side branches.
   Requirement: unit tests in step 19 pass.

### Phase B — Shared harness grows an Electron platform

8. **Add `apps/smoke-tests/lib/electron.sh`.**
   Implement the same lifecycle surface as android/ios:
   - `electron_prepare` — verify electron binary / `xvfb-run` availability on Linux.
   - `electron_build` — bundle desktop-frontend + desktop the same way `apps/desktop/smoke-tests.sh` does today (`bun run bundle` in each).
   - `electron_install` — no-op.
   - `electron_launch <port> [x_pos]` — launch with `PHOTOSPHERE_TEST_MODE=1`, `PHOTOSPHERE_TEST_PORT=<port>` (bridge port), isolated `PHOTOSPHERE_CONFIG_DIR` / `PHOTOSPHERE_VAULT_DIR` / `PHOTOSPHERE_LOG_DIR` under the test tmp dir, `PHOTOSPHERE_VAULT_TYPE=plaintext`, `NODE_ENV=testing`, optional `PHOTOSPHERE_NEWS_URL` / picker stubs. Headless via `xvfb-run -a` on Linux unless `SHOW_UI=1`. Window geometry `960x800+X+0` (default X=0; second app uses 960). Write pid to `$tmp_dir/app.pid`.
   - `electron_stop <port>` — kill pid from `$tmp_dir/app.pid` (idempotent).
   - `electron_seed_database <host_fixture_dir> <dest_name>` — copy/link fixture onto the host path the Electron app will open (host FS, not device sandbox).
   - `electron_reset_path` / `electron_cleanup` as needed for parity with mobile helpers.
   Optional later: `USE_BINARY=true` path that launches the packaged release binary (preserve today's `--binary` behaviour if cheap; otherwise defer with a note in Notes).
   In `apps/smoke-tests/lib/common.sh`, extend `load_platform` to accept `electron` and source `electron.sh`.
   Requirement: `bash -n` clean on all touched shell files.

9. **Support multiple concurrent apps (two bridges) for Electron LAN tests.**
   Desktop `7-share-secret` / `8-share-database` start two Electron processes with two control ports. The shared `start_app` today starts one bridge per tmp dir.
   Keep that model: each tmp dir (`…/sender`, `…/receiver`) gets its own bridge + launch. Do not require a multi-client single bridge.
   Ensure `start_app` / `stop_app` take a tmp dir (already do) and that `electron_launch` reads config/vault/log dirs from that tmp dir.
   Add an optional window X offset argument through to `electron_launch` so the receiver can sit at `+960`.
   Requirement: `bash -n` clean; covered by step 20 two-app scenarios.

10. **Unify seeding helpers without weakening mobile.**
    Mobile already seeds via `${PLATFORM}_seed_database` (adb/simctl) and bridge commands (`seed-databases`, `seed-secrets`, `seed-recent`, `seed-news`, `reset-config`). Electron seeds by writing host vault/config/CLI-init paths.
    In `apps/smoke-tests/lib/common.sh` (or `lib/seed.sh` sourced by it), add thin wrappers the test bodies call:
    - `seed_database <fixture_host_path> <name>` → `${PLATFORM}_seed_database …`
    - `seed_vault_secret` / host `databases.toml` helpers for Electron where the bridge seed commands are not the Electron path
    Do **not** stub mobile seeding as "not available". Platform-specific details stay in `electron.sh` / `android.sh` / `ios.sh`.
    Where Electron needs host-FS setup the bridge cannot do (CLI `init`/`add`, raw vault JSON, `databases.toml`), keep that in the Electron launcher helpers or behind `if [ "$PLATFORM" = "electron" ]` blocks inside the shared test body.
    Requirement: existing mobile tests keep working unchanged after any rename to wrappers.

11. **Upgrade `run.sh` for Electron runner features.**
    Extend `apps/smoke-tests/run.sh` so that when `PLATFORM=electron` (or via flags):
    - Default parallel batches of 2 for tests without a `.sequential` marker; `.sequential` tests run alone (needed for two-app LAN).
    - `--sequential` and `--parallel [N]` flags matching today's desktop runner.
    - Single-test selection by number or fuzzy name (`bun run test:electron -- 4` / `import`).
    - Per-test timeout (120s) and log capture under `<test>/tmp/test-run.log`.
    - Wipe `<test>/tmp` before each run (already).
    Android/ios can stay sequential-only (device contention); do not force parallel on mobile.
    Update the `PLATFORM` check to allow `electron`.
    Requirement: `bash -n` clean; step 20 exercises parallel + sequential paths.

12. **Add platform allow/skip markers.**
    Introduce an optional per-test file (e.g. `.platforms`) listing allowed platforms, or `.skip-<platform>` markers.
    Defaults: a test with no marker runs on all platforms.
    Mark mobile-only tests so Electron skips them: `28-host-emulator-comms`, and any scenario that cannot run without a device (`9-share-roundtrip` may run on Electron if `/lan-share-roundtrip` works there; if not, skip on electron).
    Mark Electron-only full round-trips if a shared body needs a reduced mobile variant: prefer one body with `if [ "$PLATFORM" = "electron" ]` for the receiver half rather than two copies.
    Requirement: runner prints `SKIP` for excluded platforms; exit code remains success when all non-skipped tests pass.

### Phase C — Merge test bodies and retire the desktop harness

13. **Merge each overlapping scenario into one shared body.**
    For every shared name under Current inventory, edit `apps/smoke-tests/tests/<n>-<name>/test.sh` so it is the single source:
    - Source `../../lib/common.sh`.
    - Use `start_app` / `wait_for_ready` / `send_command` / `wait_for_log` / `check_no_errors` / `stop_app`.
    - Use `seed_database` / platform seed helpers instead of desktop-only path wiring.
    - Drive UI flows (not dropped `/create-database` / `/import-assets` shortcuts) so Electron and mobile exercise the real dialogs.
    - Guard host-filesystem assertions with `if [ "$PLATFORM" = "electron" ]` (restore asserts the mobile port dropped where Electron can still check files).
    - For `7-share-secret` and `8-share-database`: on Electron run the full two-app flow (`.sequential`); on mobile keep the sender-only (or round-trip helper) behaviour already on the mobile branch.
    - Keep `0-launch-and-navigate` runnable on Electron (cheap bridge smoke) unless it is android-specific.
    Requirement: `bash -n` clean on every `test.sh`.

14. **Repoint root scripts.**
    In root `package.json`:
    - `test:electron` → `cd ./apps/smoke-tests && PLATFORM=electron ./run.sh`
    - `test:electron:seq` → same with `--sequential`
    - Keep `test:and` / `test:ios` as they are.
    - Keep `test:electron` inside `test:all` and `smoke`.
    Point `stories` / Electron path of `scripts/story-player.sh` at the shared `common.sh` + `PLATFORM=electron` (stop sourcing `apps/desktop/smoke-tests/lib/common.sh`).
    Requirement: script names unchanged for callers.

15. **Migrate remaining desktop-harness consumers.**
    - Update `cli-desktop-lan-share-smoke-tests.sh` to source `apps/smoke-tests/lib/common.sh` with `PLATFORM=electron` (or a thin wrapper that sets it).
    - Update `apps/desktop/screenshots/capture-ux.sh` similarly.
    - Delete or thin-wrap `apps/desktop/cycle-stories-smoke-test.sh` to call `scripts/story-player.sh --platform electron` so there is one stories cycler.
    Requirement: `grep -rn "desktop/smoke-tests" --include='*.sh' --include='*.md' --include='package.json'` shows no remaining runtime references (docs/plans history excluded).

16. **Retire the in-process server and old desktop suite.**
    Delete:
    - `apps/desktop/src/lib/test-control-server.ts` and its unit test file.
    - `apps/desktop/smoke-tests/` (all numbered dirs + `lib/`).
    - `apps/desktop/smoke-tests.sh`.
    Requirement: `bun run c` / compile clean; `grep -rn "TestControlServer" apps packages` returns nothing.

17. **Delete the superseded draft plan on the mobile tree.**
    When this plan is the active one on the branch that has `apps/smoke-tests`, remove `docs/plans/new/plan-electron-host-bridge-smoke-tests.md` (or move it to `docs/plans/done/` with a one-line pointer to this file) so there is a single plan of record.

### Phase D — Automated verification

18. **Unit-test driver platform handlers.**
    Update `packages/user-interface/src/test/lib/test-driver.test.ts` (and WS tests if present) to cover:
    - provided `screenshot` handler invoked and value returned;
    - provided `quit` handler invoked;
    - unknown command with no platform handler still throws.
    Requirement: `bun run test -- test-driver` passes.

19. **Unit-test bridge electron branches.**
    Update `apps/smoke-tests/src/test/control-bridge.test.ts`:
    - `platform: 'electron'` `/screenshot` forwards `screenshot` and writes decoded base64 to `outputPath`;
    - `platform: 'electron'` `/quit` forwards `quit`;
    - existing android/ios tests unchanged.
    Requirement: smoke-tests package tests pass.

20. **Electron suite parity.**
    Run `bun run test:electron` (shared harness). Every scenario that passed under the old desktop harness must pass. Include at least one scenario that hits `/screenshot` and one that hits `/quit`. Confirm `.sequential` two-app tests still pass and parallel batches do not flake them.
    Requirement: full electron suite green.

21. **Mobile non-regression.**
    Run `bun run test:and` (and `bun run test:ios` where the environment has Xcode). Pass/fail set for previously passing mobile tests must be unchanged by the shared-body refactor.
    Requirement: no new mobile failures attributable to this merge.

22. **Compile and full gate.**
    Run `bun run c` for the whole repo, `bun run test` for unit tests, and `bun run test:all` (includes the new `test:electron`).
    Requirement: all green.

## Unit Tests

- `installTestDriver`: platform `screenshot` / `quit` handlers; unknown command without handler throws.
- `connectTestDriverWebSocket`: with `platformHandlers`, `screenshot` reply `value` matches handler return; existing ready/log/command tests still pass.
- `ControlBridge`: electron `/screenshot` and `/quit` branches as above.
- Main-process `test-capture-page` / `test-quit`: not unit-tested directly; covered by electron e2e screenshot/quit scenarios.

## Smoke Tests

- `PLATFORM=electron` full `apps/smoke-tests/tests/*` (minus skip-marked mobile-only): parity with former `apps/desktop/smoke-tests`.
- Two-app `.sequential` tests `7-share-secret` and `8-share-database` on electron.
- `PLATFORM=android` (and ios when available): unchanged pass/fail for existing mobile scenarios.
- `scripts/story-player.sh --platform electron` still completes a stories cycle after the harness repoint.

## Verify

- `bun run c` passes.
- `bun run test` passes (including test-driver and control-bridge updates).
- `bun run test:electron` passes with shared harness; pass set matches pre-migration desktop suite for overlapping scenarios.
- `bun run test:and` shows no regressions vs pre-migration mobile.
- `bun run test:all` passes with `test:electron` still wired in.
- `grep -rn "TestControlServer" apps packages` is empty.
- `apps/desktop/smoke-tests` and `apps/desktop/smoke-tests.sh` are gone.
- No runtime script still sources `apps/desktop/smoke-tests/lib/common.sh`.

## Notes

- Screenshot on Electron stays in-app (`capturePage` → base64 → bridge writes file) because host capture of an xvfb window is fragile. That is why the driver gains `platformHandlers` instead of forcing host-side screenshots for every platform.
- Security win after Phase C: the shipped Electron app has no listening test HTTP server; test mode only opens an outbound WebSocket when `testMode` + `testBridgePort` are present.
- Quit: Electron forwards to the app (`test-quit` → `app.quit()`); `electron_stop` kills the pid as a backstop. Mobile quit stays host-side.
- Old `TestControlServer` endpoints `/create-database` and `/import-assets` are not required if migrated tests drive the real UI. If a test still depends on a dropped shortcut, rewrite it to the UI path rather than re-adding the shortcut on the bridge for Electron only.
- Numbering quirks (two `17-*` dirs, mobile `9-share-roundtrip` alongside `9-view-secret`) can stay as-is for this merge; renumbering is a separate cleanup.
- Risk: `electron_build` must reproduce today's bundle steps or Electron will launch stale renderer/main code.
- Risk: parallel electron runs need unique tmp dirs, ports, and config/vault dirs per test (already true per-test tmp); two-app tests must remain `.sequential`.
- `--binary` packaged-app mode is nice-to-have; implement in `electron_launch` if the old path is a straight port, otherwise leave a follow-up note rather than blocking the merge.
