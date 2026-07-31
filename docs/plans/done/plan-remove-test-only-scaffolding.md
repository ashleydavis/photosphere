# Remove test-only scaffolding from the app

## Overview

The app ships code that exists only so tests can set up state: seeding functions for the databases, recents and news lists, a reset-config path, and the driver commands, window events and provider handlers that reach them. None of it serves a user. It exists because the mobile config lived in WebView localStorage, where nothing outside the app could write it, so the tests were given a way in through the app instead. Mobile config is now `databases.toml` in the app's storage sandbox, so a test can set that state up from outside the way the desktop tests already do, by writing the file before the app starts. This plan removes the scaffolding whose reason has gone, and replaces it with outside-the-app setup so every test keeps working.

The test driver itself stays. So do the injection points for things a test cannot reach from outside: the native file picker, the folder prompt, the share sheet, and the deterministic uuid generator. Removing those would leave the mobile and Electron smoke suites unable to drive the app at all. The line this plan draws is: scaffolding that substitutes for state a test could write directly is removed; scaffolding that substitutes for a native interaction stays.

## Issues

## Steps

1. **Inventory what exists.** Search the shipped app code for test-only surface and write the findings into this plan under Notes as a table of symbol, file, who calls it, and what state it sets up. Cover at least `packages/mobile-frontend/src/lib/mobile-config-store.ts`, `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx`, `packages/user-interface/src/lib/test-driver.ts`, `apps/smoke-tests/lib/control-bridge.ts`, and the desktop equivalents under `apps/desktop/src`. Classify each entry as REMOVE (state a test could set up from outside) or KEEP (substitutes for a native interaction, or is the driver transport). Produce no code changes in this step.

2. **Decide the replacement for each REMOVE entry.** For each one, record in Notes how the corresponding test will set that state up instead, naming the harness function that will do it. Expect most to become "write `databases.toml` into the app's storage before launch", mirroring how the desktop tests pre-write `~/.config/photosphere/databases.toml`. Identify any REMOVE entry with no outside-the-app equivalent and reclassify it as KEEP with the reason. Produce no code changes in this step.

3. **Add the harness seeding helpers.** In `apps/smoke-tests/lib/android.sh` and `apps/smoke-tests/lib/ios.sh`, add a function that writes a databases config into the app's storage sandbox, alongside the existing `android_seed_database`. Reuse the TOML writing already used by `apps/android-frontend/scripts/run-android.sh` rather than writing a second implementation. Must compile and be exercised by at least one converted test before the step is complete.

4. **Convert the tests, one command at a time.** For each REMOVE entry, change the smoke tests that use it to call the new harness helper instead of `send_command ... seed-*`, then confirm those tests pass on both platforms. Convert one command across all its tests before starting the next, so the suite is never half-migrated.

5. **Delete the scaffolding.** Once no test calls a REMOVE entry, delete it and everything that exists only to reach it: the function in `mobile-config-store.ts`, its handler in `platform-provider-mobile.tsx`, its window event and payload type in `test-driver.ts`, its command in `control-bridge.ts`, and the desktop equivalent where one exists. Update the unit tests that covered the deleted functions.

6. **Record the rule's effect.** Update `docs/testing/README.md` with a short note on how mobile tests seed state now (write the config file, do not add app code), so the next person does not reintroduce what this plan removes.

## Unit Tests

- Update `packages/mobile-frontend/src/test/mobile-config-store.test.ts` to drop the cases covering deleted seeding functions, keeping coverage of the functions that remain.
- Add a unit test for any new pure function introduced in step 3 (for example config-text generation, if the TOML writing is factored into a shared function rather than reused as-is).
- No new unit tests for the provider or driver: they are React and transport code, covered by the smoke tests below.

## Smoke Tests

- Every mobile smoke test currently calling `seed-databases`, `seed-recent`, `seed-news` or `reset-config` must pass unchanged in behaviour after conversion, on Android and iOS.
- The tests most exposed to this change, because they depend on seeded config state, are `3-open-database`, `16-remove-recent-database`, `17-news-notifications`, `29-stale-recent-database` and `36-prefetch-database`. Run these first after each conversion.
- The desktop Electron suite must pass unchanged, as evidence the shared `test-driver.ts` edits did not break the platform that was not being migrated.

## Verify

- `bun run compile` completes with no errors.
- `bun run test` passes for every package.
- `bun run test:and` passes all tests on an emulator.
- `bun run test:ios` passes all tests on a simulator.
- `bun run test:electron` passes.
- Grep confirms no remaining references to the deleted symbols anywhere outside the plan and docs.

## Notes

### Step 1: inventory

| Symbol | File | Called by | State it sets up | Class |
| --- | --- | --- | --- | --- |
| `seedDatabases` | `packages/mobile-frontend/src/lib/mobile-config-store.ts` | `handleSeedDatabases` in `platform-provider-mobile.tsx` | The `databases` list in `databases.toml` | REMOVE |
| `seedRecentDatabases` | `packages/mobile-frontend/src/lib/mobile-config-store.ts` | `handleSeedRecent` in `platform-provider-mobile.tsx` | The `recentDatabaseNames` list in `databases.toml` | REMOVE |
| `resetConfig` | `packages/mobile-frontend/src/lib/mobile-config-store.ts` | `handleResetConfig` in `platform-provider-mobile.tsx` | Empties `databases.toml`; removes the news, shown-news and legacy plaintext-secrets keys from WebView localStorage | REMOVE |
| `seedNews` | `packages/mobile-frontend/src/lib/mobile-config-store.ts` | `handleSeedNews` in `platform-provider-mobile.tsx` | The `photosphere.news` list in WebView localStorage | KEEP |
| `handleSeedDatabases`, `handleSeedRecent`, `handleResetConfig` | `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx` | The window events below | As above | REMOVE |
| `handleSeedNews` | `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx` | `TEST_SEED_NEWS_EVENT` | As above | KEEP |
| `TEST_SEED_DATABASES_EVENT`, `doSeedDatabases`, `ITestCommandPayload.databases`, `ISeedDatabaseEntry` | `packages/user-interface/src/lib/test-driver.ts` | `seed-databases` driver command | As above | REMOVE |
| `TEST_SEED_RECENT_EVENT`, `doSeedRecent`, `ITestCommandPayload.recent` | `packages/user-interface/src/lib/test-driver.ts` | `seed-recent` driver command | As above | REMOVE |
| `TEST_RESET_CONFIG_EVENT`, `doResetConfig`, `ITestResetConfigEventDetail` | `packages/user-interface/src/lib/test-driver.ts` | `reset-config` driver command | As above | REMOVE |
| `TEST_SEED_NEWS_EVENT`, `doSeedNews`, `ISeedNewsItem`, `ITestCommandPayload.news` | `packages/user-interface/src/lib/test-driver.ts` | `seed-news` driver command | As above | KEEP |
| `POST /seed-databases`, `POST /seed-recent`, `POST /reset-config` and their payload fields | `apps/smoke-tests/lib/control-bridge.ts` | 34 smoke tests | As above | REMOVE |
| `POST /seed-news` and its payload field | `apps/smoke-tests/lib/control-bridge.ts` | `17-news-notifications` | As above | KEEP |
| `get-storage` command and `GET /get-storage` | `test-driver.ts`, `control-bridge.ts` | `39-secret-in-keychain` | Reads nothing; asserts a localStorage key is absent | KEEP |
| `setInjectedPickedFiles`, `setInjectedExportOutcome`, `setInjectedPickFolderResult`, `TEST_MENU_EVENT`, `TEST_OPEN_DATABASE_EVENT`, `TEST_NOTIFY_DATABASE_EDITED_EVENT`, `cycle-advance`, `installTestDriver`, `signalTestAppReady` | `test-driver.ts`, `platform-provider-mobile.tsx` | Every mobile smoke test | Native interactions and the driver transport | KEEP (plan scope boundary) |
| Desktop equivalents | `apps/desktop/src` | none | none | None exist: the desktop tests already pre-write `~/.config/photosphere/databases.toml`, so there is nothing to remove |

### Step 2: replacements

| REMOVE entry | How the test sets that state up instead |
| --- | --- |
| `seed-databases` | `${PLATFORM}_seed_databases_config '<databases json>' '<recent names json>'` writes `databases.toml` into the app's storage sandbox before the app launches, the same move as desktop pre-writing `~/.config/photosphere/databases.toml`. Added to `apps/smoke-tests/lib/android.sh` and `ios.sh`; the TOML text comes from `buildDatabasesConfigToml` in `packages/node-api/src/lib/databases-config.worker.ts`, the same module `registerDatabaseInConfig` (used by `run-android.sh`) writes through. |
| `seed-recent` | The same helper: recents are the second argument, because both lists live in the one file and a test seeding both wrote it twice. |
| `reset-config` | `${PLATFORM}_reset_app_state` before `start_app`. On Android `adb shell pm clear` wipes the app's whole data directory (storage sandbox, WebView localStorage and the Keystore-backed keychain). On iOS the app's data container is emptied and `xcrun simctl keychain <udid> reset` clears the simulator keychain. This resets strictly more than `resetConfig` did (it also clears the keychain, which the app-side reset needed a separate `secretStore.clearSecrets()` call for), and it runs with the app stopped, so nothing can write state back underneath it. |

`seedNews` is reclassified KEEP. News lives only in `photosphere.news` / `photosphere.shownNews` in WebView localStorage, which no host-side tool can write: on Android it is inside the WebView's own storage database and on iOS inside the WebKit website-data store. Moving the news feed to a file the worker reads would be a change to how the feature works in production, which the plan already calls out as separate work. `reset_app_state` does clear those keys (it wipes the WebView's storage), so the seeding is the only part that stays.

- Scope boundary: the driver transport (`installTestDriver`, `startTestDriverFromGlobal`, `signalTestAppReady`, the WebSocket bridge) and the native-interaction injection points (`setInjectedPickedFiles`, `setInjectedExportOutcome`, `setInjectedPickFolderResult`, the deterministic uuid generator) stay. Removing them stops all mobile and Electron smoke tests from functioning.
- `seedNews` is the one REMOVE candidate expected to have no file to write: news lives in `photosphere.news` and `photosphere.shownNews` in localStorage, with no desktop file equivalent. Step 2 should decide whether it becomes KEEP, or whether news config moves to a file first as separate work.
- The rule this plan follows is now in `CLAUDE.md`: test-only scaffolding in app code needs the human user's approval or is not added at all.
- Do not commit any of this work without the user's review and approval.
