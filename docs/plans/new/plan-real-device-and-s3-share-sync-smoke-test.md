# Prefer a real Android device for `test:and`, and add an encrypted-S3 share-and-sync smoke test

## Overview
Two separate pieces of work that both land in the Android mobile test path. First, `bun run test:and` currently never selects a plugged-in physical device: `android_device_slots` only ever offers pool emulators or emulators holding a `192.168.55.x` address on `wlan0`, and a phone on the developer's own wifi holds no such address, so it is filtered out before the run starts. `android_require_ready` also refuses to start at all unless an emulator is on the host LAN bridge. The deploy script `apps/android-frontend/scripts/run-android.sh` already implements the rule the smoke harness is missing ("a plugged-in device wins, because the reason to have one attached is to test on it"), so this plan mirrors that rule into the harness and fixes the three places that assume the device is an emulator: the readiness check, the host address the app is pointed at, and the LAN-bridge requirement. `bun run test:and:unit` runs `:app:testDebugUnitTest`, a host JVM task over `apps/android-frontend/android/app/src/test/java`, so no device is involved there and nothing needs to change; the plan verifies that rather than assuming it.

Second, a new mobile smoke test (`apps/smoke-tests/tests/45-s3-share-replica-sync`) that covers the whole real-world flow the app exists for: an encrypted database in an S3 bucket, shared to the phone over the LAN with the CLI, opened on the phone, partially replicated onto the device, edited on the device, and synced back up to the bucket. It is the first test that proves an edit made on device reaches an encrypted S3 origin, and the first that asserts the sync early-out fires when there is nothing to sync. Six small app changes are needed to make the flow drivable and observable: three `data-id` attributes on existing controls, and a `synced` flag on the worker's `sync-completed` message so the app log distinguishes "the sync ran and did nothing" from "the sync ran and pushed changes".

## Issues
<empty>

## Steps

### Part A: prefer a plugged-in real device for `test:and`

1. **Add `android_hardware_devices` to `apps/smoke-tests/lib/android.sh`.**
   - Prints one serial per line for every attached device adb reports in the `device` state whose serial does NOT begin with `emulator-`.
   - Mirrors `hardware_targets` in `apps/android-frontend/scripts/run-android.sh`; the comment block must cross-reference that function and record the same reasoning (a local emulator is always `emulator-<port>`, so anything else is a real device, including one reached with `adb connect` as `<host>:<port>`).
   - Deliberately ignores `offline` and `unauthorized` entries.

2. **Reorder `android_device_slots` in `apps/smoke-tests/lib/android.sh`.**
   - New order: `PHOTOSPHERE_ANDROID_DEVICES` override, then `android_hardware_devices`, then `android_pool_devices`, then `android_ready_devices`.
   - Comment block states that a plugged-in device wins over the pool for the same reason `run-android.sh` gives, and warns that this makes the run single-device (no five-way emulator parallelism) while a phone is attached.

3. **Make `android_require_ready` accept a hardware device in `apps/smoke-tests/lib/android.sh`.**
   - Before the existing `PHOTOSPHERE_NO_LAN_BRIDGE` branch and the bridge-status branch, check `android_hardware_devices`. When one or more are attached, log which device the run will use and return 0 without consulting `emulator.sh status`.
   - Comment block records why: the emulator LAN bridge exists to give an emulated guest a route to the host, and a phone on the same physical LAN as the host already has one, so demanding the bridge would refuse a run on the very device that needs it least.

4. **Make `android_host_address` return a device-reachable address in `apps/smoke-tests/lib/android.sh`.**
   - Keep the `PHOTOSPHERE_ANDROID_TEST_HOST` override first.
   - Add a branch before the `wlan0` polling: when the current `ANDROID_SERIAL` does not begin with `emulator-`, print `127.0.0.1` and return. The comment must say that this is correct only because every host port a test serves is reversed onto the device (step 5), and that the `wlan0` poll below is meaningless on a real phone (its address is on the developer's LAN, not `192.168.55.x`).
   - Everything already goes to stderr in this function; the new branch must not print anything on stdout except the address.

5. **Add a per-platform "expose a host port to the device" hook.**
   - `android_expose_host_port <port>` in `apps/smoke-tests/lib/android.sh`: runs `adb reverse "tcp:$port" "tcp:$port"` when the current `ANDROID_SERIAL` is a hardware device, and is a no-op on an emulator (which reaches the host directly at `192.168.55.1` or `10.0.2.2`).
   - `ios_expose_host_port <port>` in `apps/smoke-tests/lib/ios.sh`: a no-op, because the simulator shares the host's network stack. It exists so `common.sh` can call the hook unconditionally.
   - Comment blocks on both.

6. **Call the new hook from `start_s3_emulator` in `apps/smoke-tests/lib/common.sh`.**
   - After `source "$state_dir/env"` and before computing `S3_ENDPOINT`, call `"${PLATFORM}_expose_host_port" "$S3_EMULATOR_PORT"`.
   - The existing `S3_ENDPOINT` line already uses `"${PLATFORM}_host_address"`, so with step 4 in place a real device gets `http://127.0.0.1:<port>` and reaches the host MinIO through the reverse.

7. **Make `require_lan_bridge` in `apps/smoke-tests/lib/common.sh` accept a hardware device.**
   - Immediately after the `[ "$PLATFORM" != "android" ]` early return, return 0 when `android_hardware_devices` reports the current `ANDROID_SERIAL` (or, more simply, when `ANDROID_SERIAL` does not begin with `emulator-`), logging that the device is on the real LAN with the host so the emulator bridge is not what makes host-to-device sharing work here.
   - Comment block must state plainly that this trusts the phone and the host to be on the same LAN segment, and that a network with client isolation will fail the transfer loudly rather than be detected up front.

8. **Confirm `test:and:unit` needs no change.**
   - Read `apps/android-frontend/package.json` (`test:unit` runs `bun run sync` then `android-gradle.sh :app:testDebugUnitTest --rerun-tasks`) and `apps/android-frontend/scripts/android-gradle.sh`.
   - `testDebugUnitTest` compiles and runs `apps/android-frontend/android/app/src/test/java/**` on the host JVM, so there is no device selection to make. Make no code change. Record the finding in this plan's Notes section when the step is executed, and say so in the final report rather than silently doing nothing.

9. **Compile and run the existing Android suite unchanged.** `bun run compile` must pass, `bun run test` must pass, and `bun run test:and` must pass on the emulator pool exactly as before (the new branches are all inert when no hardware device is attached). Run `bun run emu:and:pool:status` at the moment the suite is started to know what the run is actually using; never assume.

### Part B: app changes needed by the new smoke test

10. **Add `ISyncCompletedMessage` to `packages/api/src/lib/sync-database.types.ts`.**
    - Fields: `type: "sync-completed"`, `databasePath: string`, `synced: boolean`.
    - `synced` is documented as "false when the sync ran but both sides already held identical content, so nothing was transferred".
    - Export it from the package's index alongside `ISyncSkippedMessage` and `ISyncBatchMessage`.

11. **Send the typed message from `syncDatabaseHandler` in `packages/node-api/src/lib/sync-database.worker.ts`.**
    - Replace the untyped `context.sendMessage({ type: "sync-completed", databasePath: data.databasePath })` at the end of the handler with an `ISyncCompletedMessage` carrying `synced: result.synced`.
    - Leave the two existing `log.info` lines and the `sync-started` message exactly as they are, so nothing that already waits on them changes.

12. **Log the distinction in `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx`.**
    - In the `subscribeMobileTaskMessage` effect, change the `sync-completed` branch to log `Sync completed: changes synced` or `Sync completed: nothing to sync` from the message's `synced` flag.
    - The existing tests wait on the substring `Sync completed`, and `wait_for_log` matches by substring (`index()` in awk), so tests 34 and 42 keep passing untouched. Add a `//` comment saying exactly that, so nobody later "tidies" the line back.
    - Do not change `apps/desktop/src/main.ts`; the desktop relay is unaffected and its smoke tests are not part of this work.

13. **Add `data-id="asset-description-input"` to the description `Textarea` in `packages/user-interface/src/pages/gallery/components/asset-info.tsx`.**
    - One attribute on the existing element, no other change. The test driver's `type` and `get-value` both resolve a nested `input, textarea` under a `data-id`, so the same id serves for writing and reading.

14. **Add `data-id="open-info-button"` to the info button in `packages/user-interface/src/components/asset-view.tsx`.**
    - The element already carries `data-testid="open-info-button"`; the driver matches on `data-id` only, so add the `data-id` beside it and leave the `data-testid` alone.

15. **Add `data-id="close-database-button"` to the "Close database" `ListItem` in `packages/user-interface/src/components/right-sidebar.tsx`.**
    - The item is rendered only while `databasePath` is set, which is what the test relies on.

16. **Compile and test.** `bun run compile` must pass and `bun run test` must pass after steps 10 to 15, with the new unit tests from the Unit Tests section below in place.

### Part C: the new smoke test

17. **Create `apps/smoke-tests/tests/45-s3-share-replica-sync/test.sh`** (executable, `#!/bin/bash`, sourcing `../../lib/common.sh`, calling `print_test_header 45 "s3-share-replica-sync"`). Follow the header-comment style of tests 41 and 42: say what the test proves, and why each non-obvious wait is where it is. The body implements the sequence below.

18. **Set up the host side of the test.**
    - `require_lan_bridge` first, before the `trap` is armed (as test 26 does), because the CLI sender has to reach the device.
    - `trap 'stop_app "$APP_PORT" "$TMP_DIR"; stop_s3_emulator "$S3_STATE_DIR"' EXIT`.
    - `start_s3_emulator "$TMP_DIR/s3"`, then set `S3_DB_PATH="s3:$S3_EMULATOR_BUCKET/shared-encrypted"`.
    - Export `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT="$S3_ENDPOINT"` and `AWS_REGION=us-east-1` for the host CLI calls, as test 42 does. Use `$S3_ENDPOINT` (the device-reachable address) rather than loopback so the host and the device agree on one endpoint, which matters because the same endpoint string is what gets shared to the phone inside the S3 secret.

19. **Build the encrypted S3 database on the host with `run_cli`.**
    - `secrets add --yes --name shared-s3 --type s3-credentials --value '<json>'` where the JSON carries `region`, `accessKeyId`, `secretAccessKey` and `endpoint` (build it with `jq -n` so quoting is not hand-rolled; the field names must match what `resolveDatabaseSharePayload` in `packages/api/src/lan-share/lan-share-resolve.ts` reads).
    - `init --db "$S3_DB_PATH" --generate-key --key shared-enc-key --yes`.
    - `dbs add --yes --name shared-db --description "Encrypted S3 database" --path "$S3_DB_PATH" --s3-cred shared-s3 --encryption-key shared-enc-key`.
    - `add "$REPO_DIR/test/test.jpg" --db "$S3_DB_PATH" --key shared-enc-key --yes` (one photo is enough).
    - Every call checked; on failure print the CLI output and exit 1, the way `create_database` in `lib/common.sh` does.

20. **Receive the database on the device through the real Receive Database dialog.**
    - `"${PLATFORM}_reset_app_state"`, `start_app`, `wait_for_ready`.
    - Navigate to `databases`, open `page-actions-menu`, click `receive-database-button`, wait for `Receive database dialog opened`.
    - Type `4321` into `receive-database-code-input`, click `receive-database-start-button`, `sleep 3`, then `cli_send_expect_success "$TMP_DIR" dbs send --yes --name shared-db --code 4321`.
    - Wait for `Database review step`, click `receive-database-save-button`, wait for `Database imported`, click `receive-database-close-button`.
    - Assert with `wait_for_value "$APP_PORT" "database-row-name-shared-db" "shared-db"` that the entry really persisted (this is what proves the S3 credentials and the encryption key landed in the device keychain too, because the entry references them by name).

21. **Open the received S3 database and see the one photo.**
    - `send_command "$APP_PORT" menu '{"itemId":"open-database"}'`, wait for `Open database dialog opened`, click `database-list-item-0`.
    - Wait for `Load assets task completed: 1 assets loaded`, navigate to `/`, wait for `Gallery loaded: 1 assets`.
    - This is the assertion that the shared S3 credentials and encryption key both work from inside the embedded JS engine.

22. **Close the database through the app's own UI.**
    - Click `right-sidebar-button`, then `close-database-button` (added in step 15).
    - Assert the app returned to its no-database screen with `wait_for_value "$APP_PORT" "no-database-loaded" "."` (the element renders only when no database is open).
    - Closing here also removes the auto-open race that tests 17 and 36 both had to work around before opening the card's action menu.

23. **Replicate the S3 database partially onto the device.**
    - Navigate to `databases`, wait for `Databases page loaded`.
    - Click `entity-actions-menu`, click `replicate-database-button`, wait for `Replicate database dialog opened`.
    - Type `local-replica` into `replicate-dest-path-input`, click `replicate-mode-partial`, click `replicate-start-button`, wait for `Replication completed for`, click `replicate-close-button`.
    - The replica is left unencrypted on device storage: `replicateDatabaseHandler` copies through the decrypted asset-storage layer, and leaving `destEncryptionKey` unset is what the dialog does by default. Record that decision in the test's header comment, because it is a deliberate choice and not an oversight.
    - `replicate()` in `packages/node-api/src/lib/replicate.ts` writes `origin: sourcePath` into the destination's `.db/config.json`, so the replica points at the S3 path with no extra step. The origin resolves its credentials from the received `shared-db` entry, which names the same path.

24. **Register and open the partial replica, and see the one photo.**
    - Click `page-actions-menu`, click `add-database-button`, wait for `Add database dialog opened`.
    - Type `local-replica` into both `database-name-input` and `database-path-input`, click `add-database-confirm`, wait for `Database entry added` then `Database opened`.
    - Navigate to `/`, wait for `Gallery loaded: 1 assets`.
    - Assert the prefetch pulled the thumbnails down out of the bucket with `"${PLATFORM}_wait_for_file" "local-replica/thumb"`, the same assertion test 42 makes.

25. **Assert the sync runs and early-outs with nothing to do.**
    - `send_command "$APP_PORT" notify-database-edited '{}'` to trip the scheduler's 10 second debounce, as tests 34 and 42 do.
    - Wait for `Sync started`, then wait for `Sync completed: nothing to sync`.
    - That second line is the whole point of the app change in steps 10 to 12: it proves the sync really ran against the S3 origin and that `syncDatabases` took its identical-content-hash early-out, rather than proving only that a sync happened.

26. **Edit the photo's description on the device and assert it shows in the info panel.**
    - `long-press-click` on `gallery-thumb`, wait for `AssetView opened`.
    - Click `open-info-button`, type `Edited on the device` into `asset-description-input`.
    - Wait for `Sync started`. This is the race-free signal that the edit was persisted: `persistDatabaseOps` in `packages/user-interface/src/context/asset-database-source.tsx` calls `platform.notifyDatabaseEdited()` only after the `apply-database-ops` POST has resolved, and that is what schedules the sync. Do not `sleep` for the 500ms description debounce.
    - Assert the description is shown by reading it back with `wait_for_value "$APP_PORT" "asset-description-input" "Edited on the device"`.

27. **Assert the second sync did some work.**
    - Wait for `Sync completed: changes synced`.
    - Together with step 25 this is what proves the `synced` flag is real and not always the same value.

28. **Open the S3 database again and assert the new description is there.**
    - `send_command "$APP_PORT" menu '{"itemId":"open-database"}'`, wait for `Open database dialog opened`, click `database-list-item-0` (the received `shared-db` entry, which was registered first and so keeps index 0; the replica is index 1).
    - Wait for `Load assets task completed: 1 assets loaded`, navigate to `/`, wait for `Gallery loaded: 1 assets`.
    - `long-press-click` `gallery-thumb`, wait for `AssetView opened`, click `open-info-button`, then `wait_for_value "$APP_PORT" "asset-description-input" "Edited on the device"`.
    - This is the test's real conclusion: an edit made on the device reached an encrypted database in an S3 bucket, through the sync, and reads back decrypted.

29. **Finish with `check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error'`**, matching tests 41 and 42, then `log_success "Test 45 passed: s3-share-replica-sync"`.

30. **Watch the test fail before accepting it.** Run it with `bun run test:and -- 45` against the app WITHOUT the step 10 to 12 change first and confirm it fails at the `Sync completed: nothing to sync` wait. Then revert the assertion to the wrong value (`nothing to sync` where `changes synced` is expected) with the change in place and confirm it fails there too. Only then accept the test. Record in the final report which failures were actually observed.

## Unit Tests

- `packages/node-api/src/test/lib/sync-database.worker.test.ts` (extend the existing file):
  - The `sync-completed` message carries `synced: true` when `syncDatabases` reports a sync that transferred records.
  - The `sync-completed` message carries `synced: false` when `syncDatabases` takes its identical-content-hash early-out.
  - The existing `sync-skipped` tests (no origin configured, origin merkle tree missing) still pass unchanged, confirming the early-return paths still send no `sync-completed` at all.
- No unit test for `platform-provider-mobile.tsx` (a React provider, excluded by the project rules). The one-line log choice inside it is trivial and stays inline rather than being extracted purely to gain a test; it is covered end to end by steps 25 and 27.
- No unit tests for the three `data-id` additions (attributes on React components, covered end to end by the new smoke test).
- No tests for any of the shell changes in Part A: the project rules ban `*.test.sh` and shell tests outright. Part A is proved by running the real suite (step 9 and the Verify section).

## Smoke Tests

- New: `apps/smoke-tests/tests/45-s3-share-replica-sync/test.sh`, as specified in Part C. It is picked up automatically by `discover_tests` in `apps/smoke-tests/run.sh` and needs no registration in `what-changed.json` (the `test:and` target already watches all of `apps/smoke-tests`).
- Behaviours the new test covers that nothing else does: receiving an encrypted S3 database over the LAN onto a phone; opening an encrypted S3 database on device from shared credentials; the sync early-out being observable; an on-device metadata edit reaching an encrypted S3 origin.
- Existing tests that must keep passing untouched, because they wait on the log lines this plan edits: 34-sync and 42-s3-sync-prefetch (both wait on the substring `Sync completed`), 17-replicate-database and 36-prefetch-database (the replicate dialog flow), 26-receive-database (the receive dialog flow), 19-download-single-asset (`gallery-thumb` and `AssetView opened`).
- Part A has no new smoke test of its own. Its check is that `bun run test:and` still passes on the emulator pool, and that a run with a phone attached selects the phone. The latter cannot be asserted by an automated test on a machine with no phone plugged in, so the final report must say plainly whether it was observed or not.

## Verify

- `bun run compile` passes.
- `bun run test` passes, including the two new `sync-database.worker.test.ts` cases.
- `bun run test:everything -- --force` passes. This is the canonical check and is what the git hook runs; it covers the mobile suites, which `bun run test:all` does not.
- `bun run test:and -- 45` passes on its own, and the failure runs described in step 30 were observed before the test was accepted.
- `bun run test:and` passes for the whole Android suite, with `bun run emu:and:pool:status` run at the moment the suite starts so the report says what it actually ran on.
- With no hardware device attached, `android_device_slots` still returns exactly the devices it returned before this change (verify by reading the printed "Running on N device(s)" line against a run from before).

## Notes

- `bun run test:and:unit` needs no change. It runs `:app:testDebugUnitTest`, which compiles and runs the JUnit sources under `apps/android-frontend/android/app/src/test/java` on the host JVM. There is no device in that path at all, so there is no device preference to express. The only instrumented source set in the project is the untouched Capacitor template `ExampleInstrumentedTest.java` under `androidTest`, and no script runs it.
- Preferring a plugged-in phone means a run drops from five parallel emulators to one device, so the whole Android suite takes considerably longer while a phone is attached. That is the behaviour asked for; `PHOTOSPHERE_ANDROID_DEVICES` remains the way to force the pool back.
- The real-device path depends on the phone and the host sharing a LAN segment that passes broadcast traffic. A network with client isolation will fail `dbs send` at the "no device found" timeout. `cli_send_expect_success` already turns that into a hard failure rather than a silent pass, so the failure is loud, but it is not detected before the run starts.
- `run-as` (used by `android_seed_database`, `android_reset_path` and `android_wait_for_file`) works on a physical device because the debug APK is debuggable, which is the same thing `run-android.sh` relies on for its fixture seeding. `pm clear` in `android_reset_app_state` likewise needs nothing an emulator has and a phone does not.
- The new test leaves the on-device replica unencrypted. `prefetchDatabaseHandler` and `syncDatabaseHandler` both move files through the decrypted asset-storage layer, so a plain replica of an encrypted origin is coherent, but it does mean device storage holds plaintext copies of encrypted-at-origin assets. If that is not wanted, the replicate dialog can be driven through `replicate-configure-secrets-button` and `configure-secrets-encryption-select` to name the received encryption key, which needs no app change; the test would then also have to register the replica with that key, which the Add Database dialog cannot do today because its "Encrypted" switch carries no `data-id`. Adding that switch id is deliberately out of scope here.
- `docs/plans/new/plan-sync-early-out.md` proposes a much cheaper early-out based on a per-side change token, replacing today's content-hash comparison. Nothing in this plan blocks it: the assertion in step 25 is on the `synced: false` flag, not on how the handler decided nothing had changed, so that plan can land later without touching test 45.
- The endpoint stored in the shared S3 secret is the device-reachable one (`192.168.55.1:<port>` on a bridged emulator, `127.0.0.1:<port>` reversed on a phone). The host CLI uses the same string, which works because MinIO binds `0.0.0.0`. Using loopback for the host and the bridge address for the device would put two different endpoints in play and make the share payload wrong for one of them.
- Test 41 (`41-s3-database-lifecycle`) records that creating an S3 database from the device once failed with "Region is missing". If that fault is still live, step 21 of the new test is where it will surface, and the failure will be about opening a shared S3 database rather than creating one. Report it as found; do not work around it inside the test.
