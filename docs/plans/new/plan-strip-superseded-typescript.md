# Strip the superseded TypeScript apps and packages

## Overview

The Zig CLI (`apps/cli-zig`) and the Photosphere App on Ziggy (`apps/photosphere`, `apps/photosphere-frontend`) replace the TypeScript CLI (`apps/cli`), the Electron desktop app (`apps/desktop`, `apps/desktop-frontend`) and the Capacitor mobile apps (`apps/android-frontend`, `apps/ios-frontend`). The old apps, the TypeScript backend packages that only they used, their smoke suites and the dev web server are still in the repository. They cost install time, compile time and test time, and they keep the reader guessing which code is live. This plan removes them. Several live parts still lean on the old code: the Zig CLI smoke suite lives inside `apps/cli` and checks every database with the TypeScript CLI, the app smoke suite creates fixture databases with the TypeScript CLI, the Android build and the emulator pool take their scripts and Gradle settings from `apps/android-frontend`, and the shared UI imports types and a few plain functions from `api`, `node-api` and `vault`. Each of those is moved onto the Zig side or into a kept package before the old code is deleted. The plan ends with the TypeScript UI compiling and its unit tests passing, and the Zig unit tests, the Zig CLI smoke suite and the Photosphere App smoke suites passing.

## Issues

## Steps

Every deletion below names its exact path. A directory deletion is an `rm -r` and a directory move is a `cp -r` followed by an `rm -r`. Under the repository rules those run only when the human's message that starts the implementation authorises them, so each step lists its paths exactly.

### Part A: move the live parts off the old code

1. **Move the Android toolchain and emulator scripts into the Photosphere App.**
   - Read every file in `apps/android-frontend/scripts/` and sort it into one of two lists: scripts the Photosphere App or the emulator pool uses (from the research: `android-env.sh`, `install-android-sdk.sh`, `emulator.sh`, `emulator.md`, `emulator-config.sh`, `emulator-status-lib.sh`, `emulator-pool-monitor.sh`, `psphere-pool.slice`, and any file one of those sources), and scripts only the Capacitor app uses (from the research: `run-android.sh`, `distribute-android.sh`, `distribute-android.md`, `android-gradle.sh`, `list-targets.sh`, `write-databases-config.ts`). Confirm each placement with `git grep` for its name before acting on it.
   - Copy the first list into a new directory `apps/photosphere/scripts/android-emulator/`. Fix every relative path inside the copies (each resolves its own directory with `BASH_SOURCE`, so check every `..` they build).
   - Copy `apps/android-frontend/CLAUDE.md` to `apps/photosphere/scripts/android-emulator/CLAUDE.md` and change the paths and commands in it to the new location.
   - Add `emu:up`, `emu:pool:up`, `emu:pool:down`, `emu:pool:restart`, `emu:pool:repair`, `emu:pool:diagnose`, `emu:down`, `emu:restart`, `emu:status` and `emu:pool:monitor` to `apps/photosphere/package.json` (package name `ziggy`), each running the copied script with the same argument the `android-frontend` entry passes today.
   - In the root `package.json`, point every `emu:and:*` script at `--filter=ziggy` (and `emu:and:pool:monitor` at the new script path).
   - In `scripts/android-pool-status.sh`, `scripts/check-parallel-tests.sh`, `apps/photosphere/scripts/android-common.sh`, `apps/photosphere/scripts/setup-android.sh` and their `.md` files, change every `apps/android-frontend/scripts/...` path to the new one.
   - Check: `bun run emu:and:pool:status` runs and exits 0 or 1 (not 127 or a "No such file" error), and `bash -n` passes on every copied script.

2. **Give the Photosphere Android project its own Gradle settings.**
   - Copy `apps/android-frontend/android/variables.gradle` to `apps/photosphere/native/android/variables.gradle`.
   - In `apps/photosphere/native/android/build.gradle`, apply `variables.gradle` from its own directory, and replace the read of `ndkVersion` out of `apps/android-frontend/android/app/build.gradle` with an `ext.ndkVersion` value copied from that file. Update the comments that say the values come from the Capacitor app.
   - In `apps/photosphere/scripts/android-common.sh`, remove `PHOTOSPHERE_CAPACITOR_ANDROID_DIR`, make `photosphere_android_ndk_version` read `ndkVersion` from `apps/photosphere/native/android/build.gradle`, and make `photosphere_android_min_sdk` read from the copied `variables.gradle`. Update `apps/photosphere/scripts/android-common.md` to match.
   - In `apps/photosphere/scripts/sync-android.sh`, remove the call to `scripts/fetch-mobile-media-tools.sh android`: it fetches ImageMagick into `apps/android-frontend/android/app/src/main`, which the Ziggy build never reads (it links ImageMagick and FFmpeg from `third-party/`). Confirm that claim with `git grep -nE "jniLibs|cpp/imagemagick"` over `build.zig`, `apps/photosphere` and `third-party` before removing the call.
   - Check: `bun run build:ziggy:android` succeeds.

3. **Move the Zig CLI smoke suite into `apps/cli-zig`.**
   - Copy `apps/cli/smoke-tests-zig.sh` to `apps/cli-zig/smoke-tests.sh`, the directory `apps/cli/smoke-tests-zig/` to `apps/cli-zig/smoke-tests/`, and `apps/cli/test-cli-binaries.sh` and `apps/cli/test-cli-binaries.md` to `apps/cli-zig/`. Copy `apps/cli/check-tools.sh` too if the suite sources or runs it (check with `grep`). Both locations are two levels below the repository root, so `../../test`, `../../scripts` and `REPO_ROOT` resolve unchanged; check every relative path anyway.
   - In the root `package.json`, change `test:cli:zig` to `cd ./apps/cli-zig && bash ./smoke-tests.sh --capture-baseline test:cli:zig`.
   - In `what-changed.yaml`, remove `apps/cli` from the `test:cli:zig` target (it already lists `apps/cli-zig`).
   - In `.github/workflows/release-zig-linux.yml`, `release-zig-macos-arm64.yml`, `release-zig-macos-x64.yml`, `release-zig-windows.yml` and `ci-zig.yml`, change every `working-directory: ./apps/cli` step that runs `smoke-tests-zig.sh` to `./apps/cli-zig` running `./smoke-tests.sh`. These are edits to existing workflows. No new workflow is added.
   - In `apps/cli-zig/src/test/test-helpers.zig`, change `runCli`, `runCliToFile` and every other helper that opens `../cli` as the working directory to open `.` (the `apps/cli-zig` directory the tests run from), and update the comments that say the CLI runs in `apps/cli`, including the one in `apps/cli-zig/src/test/commands.test.zig`. Read `build.zig` around the `psi` test step to confirm what the test working directory is before changing it.
   - Check: `bun run test:zig` passes.

4. **Take the TypeScript CLI out of the Zig CLI smoke suite.**
   - In `apps/cli-zig/smoke-tests/lib/common.sh` and `apps/cli-zig/smoke-tests.sh`, change `ts_verify` to run `verify` with the Zig CLI (`get_zig_cli_command`), keeping its arguments and its `SKIP_ROOT_HASH_PRINT` handling, and rename it `verify_database` at every call site. Remove `source .../ts-verify-timing.sh`, `account_test_timing`'s verify totals, `TS_VERIFY_*`, `LAST_TS_VERIFY_NOTE` and the summary line that prints them. Delete `lib/ts-verify-timing.sh` and `lib/ts-verify-timing.md`.
   - Remove `get_cli_command` (TypeScript CLI) and `get_mk_command`. Replace each remaining use of `get_cli_command` and each `bun run start` in the suite's tests with `get_zig_cli_command`, after reading each call site: a test that compares TypeScript output against Zig output becomes a test of the Zig output against the same expected text the comparison used.
   - Delete the tests whose subject is the TypeScript CLI itself: `132-lan-share-database-ts-to-zig`, `133-lan-share-database-zig-to-ts`, `134-lan-share-secret-ts-to-zig` and `135-lan-share-secret-zig-to-ts`. In `104-no-typescript-runtime`, remove the step that checks the database with the TypeScript CLI and keep the bun-trailer and PATH checks.
   - `get_bdb_command` stays and runs `apps/bdb-cli` (see Notes); change its default from `bun run ../bdb-cli/src/index.ts` so it resolves from `apps/cli-zig`, which is the same relative path.
   - Replace the `bun "$REPO_ROOT/apps/smoke-tests/lib/write-databases-config.ts"` call in `lib/common.sh` with `psi dbs add` calls through the Zig CLI, one per entry in the JSON the caller builds, so the file is written by the product's own writer. Read the callers and test `59-dbs-add-cli` to confirm `dbs add` takes every field the seeded entries carry. If a field has no flag, write the TOML in shell with `jq` and `printf` instead, matching `packages-zig/node-api-zig/src/lib/databases-config.worker.zig`.
   - In `test-cli-binaries.sh`, remove `build_test_cli_binaries` building `psi` and `mk` with `bun build --compile`; keep building `bdb` for `--binary` runs. Update `test-cli-binaries.md`.
   - Update the header comments of `smoke-tests.sh` and each changed test so none describes a TypeScript CLI.
   - Check: `bun run test:cli:zig` passes, and `git grep -nE "ts_verify|get_cli_command|bun run start|mk-cli" apps/cli-zig` finds no match.

5. **Create the app smoke suite's fixture databases with the Zig CLI.**
   - In `apps/photosphere-smoke-tests/lib/common.sh`, make `create_database` and `run_cli` run the Zig `psi` instead of `cd apps/cli && bun run start --`. Build it once per run the way the Zig CLI suite does, by sourcing `apps/cli-zig/test-cli-binaries.sh` and calling `build_test_zig_cli` and `test_zig_cli_path`, and remove the built directory in the existing exit cleanup with `remove_test_zig_cli`. Record nothing as a long-lived process: `psi` runs in the foreground per call and exits.
   - In `apps/photosphere-smoke-tests/10-view-database/test.sh`, `28-s3-failure/test.sh`, `34-edit-asset-metadata/test.sh` and `42-s3-sync-prefetch/test.sh`, replace each `cd "$REPO_DIR/apps/cli" && bun run start --` with `run_cli` or the Zig `psi` path.
   - Fix the comments that name removed paths: `26-s3-database-lifecycle/test.sh` (`apps/cli/smoke-tests/72-s3-paths`), `56-large-asset-push/test.sh` (`packages/api/src/lan-share/lan-share-resolve.ts`, point at the Zig port in `packages-zig/api-zig` after finding it with `git grep`) and `lib/android.sh` (`apps/smoke-tests/lib/android.sh`).
   - Check: `bun run test:ziggy` passes.

6. **Move what the shared UI uses out of the packages being deleted.**
   - Copy the interfaces `IMoveAssetsData` (`packages/node-api/src/lib/move-assets.worker.ts`), `IDatabaseSummary` (`media-file-database.ts`), `IGetDatabaseSummaryData` (`get-database-summary.worker.ts`) and `ITestJobData` (`test-job.worker.ts`) into `packages/api/src/lib/`, one file per subject (`move-assets.types.ts`, `database-summary.types.ts`, `test-job.types.ts`), with any types they reference, and export them from `packages/api/src/index.ts`.
   - Copy `ISecret` from `packages/vault/src/lib/vault.ts` into `packages/api/src/lib/secret.ts` and export it.
   - Change the imports in `packages/user-interface/src/context/asset-database-source.tsx`, `components/database-summary-view.tsx`, `lib/test-jobs.ts` and `apps/photosphere-frontend/src/lib/platform-provider-ziggy.tsx` to take these from `api`. Remove `node-api` and `vault` from `packages/user-interface/package.json` and `apps/photosphere-frontend/package.json`.
   - Check: `bun run compile` passes.

### Part B: delete the old code

7. **Delete the old apps.** Remove `apps/cli`, `apps/desktop`, `apps/desktop-frontend`, `apps/dev-frontend`, `apps/dev-server`, `apps/android-frontend`, `apps/ios-frontend`, `apps/mk-cli`, `apps/smoke-tests` and `apps/ziggy-example` (tracked build output only). Remove the root files that only drove them: `cli-desktop-lan-share-smoke-tests.sh`, `run-tests.sh`, `run-cloud-storage-tests.sh`, `CLOUD_STORAGE_TESTS.md` and `test/test-cli-commands.sh`. Read each root file before deleting it to confirm it drives only removed code. Remove `scripts/run-mobile-tests.sh`, `scripts/fetch-mobile-media-tools.sh`, `scripts/update-mobile-media-tools.sh` and their `.md` files after `git grep` shows no remaining caller.

8. **Strip `packages/api` to the modules the UI uses.**
   - Keep the files the UI and `apps/photosphere-frontend` import (from the research: `lib/sync-gate.ts`, `lib/auto-import-settings.ts`, `lib/auto-import-mobile.ts`, `lib/sync-settings.ts`, `lib/load-assets.ts`, `lib/load-assets.types.ts`, `lib/import-record.ts`, `lib/import-assets.types.ts`, `lib/sync-database.types.ts`, `lib/save-assets.types.ts`, `lib/asset.ts`, `lib/database-op.ts`, `lib/op.ts`, `lan-share/index.ts`, the files added in step 6) and every file those import, found by following the imports. Delete every other source file and every test that tests only a deleted file.
   - Rewrite `packages/api/src/index.ts` to export only the kept modules.
   - Remove from `packages/api/package.json` every dependency the kept files no longer import (expected: everything except `task-queue` and `lan-share-core`).
   - Check: `bun run compile` and `bun run test` pass.

9. **Delete the packages no kept code uses.** Remove `packages/node-api`, `packages/rest-api`, `packages/mobile-frontend`, `packages/mobile-worker`, `packages/lan-share-network`, `packages/tools`, `packages/vault`, `packages/fuzzy-match` and `packages/lan-share` (an untracked build leftover). Before each, `git grep` for its package name in every remaining `package.json` and in remaining `.ts`/`.tsx` imports; a package still imported is not deleted, and the importer is fixed first. `bdb`, `storage`, `merkle-tree`, `serialization`, `encryption`, `node-utils`, `utils`, `task-queue`, `config`, `lan-share-core`, `api` and `user-interface` stay.

10. **Trim `packages/task-queue` to what the Ziggy frontend uses.** After step 9, `git grep` each export of `packages/task-queue/src/index.ts` (`WorkerQueueBackend`, `executeTaskHandler`, `registerHandler`, `getHandler`, `TaskContext` and the rest) across the remaining packages and apps. Delete each module with no importer outside `task-queue` itself, with its tests, and remove its export line. Check: `bun run compile` and `bun run test` pass.

11. **Remove the Zig fixture generators that import deleted TypeScript.** `packages-zig/api-zig/src/test/fixtures/generate.ts`, `packages-zig/vault-zig/src/test/fixtures/generate.ts`, `apps/cli-zig/src/test/fixtures/generate.ts` and `apps/cli-zig/src/test/fixtures/commander/generate.ts` import code removed above, so they can no longer run. Delete them and keep the fixture files they wrote. Change the test comments that tell the reader to regenerate with them to say the fixtures were written by the TypeScript implementation and are now the reference. Keep `packages-zig/utils-zig/src/test/fixtures/generate.ts`, which imports `packages/utils`, which stays.

12. **Fix every remaining reference to a deleted path.**
    - Run `git grep -nE "apps/(cli|desktop|desktop-frontend|dev-frontend|dev-server|android-frontend|ios-frontend|mk-cli|smoke-tests|ziggy-example)\b|packages/(node-api|rest-api|mobile-frontend|mobile-worker|lan-share-network|tools|vault|fuzzy-match)\b" -- ':!docs' ':!*.md'` and fix each hit outside `docs/` (docs are step 15).
    - Known hits from the research: `scripts/story-player.sh` (remove the `electron`, `android` and `ios` platforms and their sourcing of `apps/desktop` and `apps/smoke-tests`, keeping `ziggy`, `ziggy-android` and `ziggy-ios`), `scripts/check-parallel-tests.sh` and `scripts/find-flakey-tests.sh` (the log `find` over `apps/smoke-tests/tests` and `apps/desktop/smoke-tests`, and the `apps/smoke-tests/run.sh` comment), `scripts/lib/test-lib.sh` (the comment naming `packages/node-utils/src/lib/test-temp-dir.ts` stays valid because `node-utils` stays; confirm and leave it), `scripts/set-build-config.sh` (keeps writing `packages/config/src/index.ts`), `.github/actions/retry-install/action.yml` (`packages/tools/src/lib/image.ts`), `packages-zig/photosphere-core/src/lib/main-process.zig` and `update-and-news.zig`, `packages-zig/node-api-zig/src/lib/media-source.zig` and `source-cleanup.zig`, the `packages-zig/mobile-worker-zig` tests, `packages-zig/lan-share-network-zig/src/lib/lan-share-sender.zig`, `packages-zig/storage-zig/integration-tests/cloud-storage.test.zig`, `apps/cli-zig/src/lib/worker-pool.zig`, `apps/cli-zig/src/lib/third-party/open.zig` and `apps/cli-zig/src/test/dbs-interactive.test.zig`. Most are comments saying a Zig file ports a TypeScript one: change them to say what the code does without the removed path.
    - Update comments in `packages/user-interface/src` and `apps/photosphere-frontend/src` that name a removed path (`pages/about.tsx` names `apps/desktop/src/lib/mcp/main-bridge.ts`, `lib/test-driver.ts` names `apps/smoke-tests/lib`). Change no code there in this step.
    - In the root `package.json`, check that `setup` still covers Android and iOS setup now that `android-frontend` and `ios-frontend` are gone (`apps/photosphere` has its own `setup`), and remove any script that names a deleted package.
    - In `what-changed.yaml`, remove paths that no longer exist.
    - In `.github/workflows/*.yml`, fix each hit (for example `release-zig-android.yml` names `apps/android-frontend/scripts/emulator-config.sh`).

13. **Reinstall and rebuild the lockfile.** Run `bun install` at the root so `bun.lock` drops the deleted workspaces and their dependencies (Electron, electron-builder, Capacitor and the rest). Check: `bun install` exits 0 and `git grep -nE "\"(electron|@capacitor/[a-z]+)\"" -- '*package.json' bun.lock` finds no match.

14. **Run the whole test set.** Run `bun run tev` with no flags. The change touches `apps`, `packages`, `scripts` and `package.json`, which every target watches, so the change check runs every suite without `--force`. Every suite must pass: `compile`, `test`, `test:zig`, `test:cli:zig`, `test:ziggy` and `test:ziggy:and` on Linux. Then run `bun run test:parallel` to confirm the moved suites survive running beside each other and beside a second copy of themselves. Fix every failure at its cause.

15. **Update the documentation.**
    - `CLAUDE.md`: in Setup, describe `bun run setup` without `apps/android-frontend` and `apps/ios-frontend`; in the emulator rules, change `bun run --filter=android-frontend emu:pool:repair` and `emu:pool:diagnose` to `bun run --filter=ziggy ...` and `apps/android-frontend/CLAUDE.md` to `apps/photosphere/scripts/android-emulator/CLAUDE.md`; change the `test:cli:zig` line to say the suite is in `apps/cli-zig/smoke-tests` and checks each database with the Zig `psi verify`; in Architecture, remove the Capacitor `Mobile` and Electron `Desktop` bullets and the `mobile-frontend`/`mobile-worker` description, and describe the Photosphere App on Ziggy instead; change `bun run start -- <command> [db-path]` (from `apps/cli`) to how the Zig CLI is run; remove the rules about Electron IPC channels; check `AGENTS.md` at the root and keep it aligned if it exists.
    - Remove the guides whose subject is gone, after reading each: `docs/mobile-native-media.md` and `docs/updating-mobile-imagemagick-ffmpeg.md` if they cover only the Capacitor apps, and their links in `CLAUDE.md` and `docs/development.md`.
    - `README.md`, `docs/development.md`, `docs/testing/README.md`, `docs/tasks.md`, `docs/photosphere-on-ziggy.md`, `apps/photosphere/README.md`, `apps/photosphere-smoke-tests/README.md`, `apps/photosphere/scripts/setup-android.md`, `apps/photosphere/scripts/android-common.md`, `apps/cli-zig` docs and `packages/user-interface/src/stories/README.md` (remove the Electron and Capacitor ways to open the stories): remove every mention of the deleted apps and packages, and describe the moved suite and scripts at their new paths.
    - Run `git grep -nE "apps/(cli|desktop|android-frontend|ios-frontend|smoke-tests|mk-cli|dev-frontend|dev-server)\b|Electron|Capacitor" -- '*.md'` over everything except `docs/plans/` and fix each hit that describes the removed code as live. A doc under `docs/investigations/` that records past findings may keep its history.

## Unit Tests

- `apps/cli-zig/src/test/*.test.zig`: the existing tests that call `runCli` and `runCliToFile` run from `apps/cli-zig` after step 3. No new test: the change is the working directory, and the existing tests fail if a relative path is wrong.
- `packages/api/src/test/`: the existing tests for every kept module stay and pass after step 8. The type-only files added in step 6 have no logic to test.
- `packages/task-queue/src/test/`: the tests for every kept module stay and pass after step 10.
- No new function is written in TypeScript or Zig. The shell changes are covered by the smoke suites (the repository does not unit test shell scripts).

## Smoke Tests

- `bun run test:cli:zig` (from `apps/cli-zig`): every remaining test passes, with each database checked by the Zig `psi verify` and the seeded `databases.toml` written through `psi dbs add`.
- `bun run test:ziggy`: every scenario passes with fixture databases created by the Zig `psi`.
- `bun run test:ziggy:and`: every scenario passes with the Android build reading its Gradle settings from `apps/photosphere/native/android` and the emulator scripts from `apps/photosphere/scripts/android-emulator`.
- `bun run test:ziggy:ios` on macOS: passes (run in CI on the existing `release-zig-ios.yml`; it cannot run on the Linux development machine).
- `bun run stories:ziggy -- --headless --no-screenshots` runs to the end, which exercises the trimmed `scripts/story-player.sh` and the UI stories.
- `bun run test:parallel`: no suite fails in company.

## Verify

- `bun install` exits 0 and `bun.lock` names no Electron or Capacitor package.
- `bun run compile` passes (every remaining TypeScript package and the UI).
- `bun run test` passes (TypeScript unit tests).
- `bun run test:zig` passes (Zig unit tests).
- `bun run test:cli:zig` passes.
- `bun run test:ziggy` and `bun run test:ziggy:and` pass.
- `bun run tev` exits 0 having run every suite for the platform (read its plan output to confirm none was skipped).
- `bun run emu:and:pool:status` runs from the new script location.
- `bun run build:ziggy:android` succeeds.
- `ls apps packages` lists none of the deleted directories.
- The `git grep` in step 12 finds no match outside `docs/investigations/`, and the one in step 15 finds no doc describing removed code as live.

## Notes

- **`apps/bdb-cli` stays, and with it `bdb`, `storage`, `merkle-tree`, `serialization`, `encryption`, `node-utils` and `utils`.** The Zig CLI smoke suite's sync and metadata tests (`37` to `40`, `69`, `80`, `136` and others) use `bdb record` and `bdb edit` to read and change a record directly, and the Zig side has no `bdb` executable. Porting those two subcommands to Zig over `packages-zig/bdb-zig` is the change that lets these packages go, and is left out of this plan to keep it to the apps the request names.
- **`apps/mk-cli` goes.** The Zig CLI suite calls it only from a commented-out debug line.
- **The TypeScript cross-check is replaced, not kept.** `ts_verify` proved that every database the Zig CLI writes is readable by the TypeScript CLI. With the TypeScript CLI gone there is no reader left to be compatible with, so the check becomes a verify with the Zig CLI, which still catches a database the Zig CLI cannot read back. Tests 132 to 135 test interop with the TypeScript CLI and are deleted because their subject no longer exists.
- **`api` is kept as a stripped package rather than folded into `user-interface`.** Keeping the package name means the imports in `user-interface` and `apps/photosphere-frontend` (including the `api/src/lib/...` deep imports) keep working, which keeps the change small. Renaming it is a separate change.
- **Electron-only branches in the shared UI stay.** `packages/user-interface` still has code paths written for Electron (for example the `webUtils` comment in `platform-context.tsx`). This plan updates comments that name deleted paths and changes no UI behaviour; removing dead platform branches is a separate change with its own UI testing.
- **The emulator pool scripts move while the human may have the pool monitor running from the old path.** `emulator-pool-monitor.sh` is a long-running script, so a running copy keeps its old file open. Its lock (`/tmp/photosphere-emulator-pool-monitor.lock`) and log paths do not change. The new copy is used from the next start.
- `apps/ziggy-example` holds only tracked build output (`out/` and an `xcuserdata` file) and no source.
- `dev:ui` in the root `package.json` already runs `apps/photosphere-frontend`, so `apps/dev-frontend` and `apps/dev-server` have no remaining user.
