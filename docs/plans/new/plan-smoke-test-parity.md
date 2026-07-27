# Smoke test parity between mobile and Electron

## Overview

The Electron suite (`apps/desktop/smoke-tests/`) and the mobile suite (`apps/smoke-tests/tests/`) were built at different times and have drifted. Mobile has 38 tests, Electron has 24. Fifteen mobile tests have no Electron counterpart, two Electron tests have no mobile counterpart, and several mobile tests that share a number with an Electron test are much thinner ports that only wait for a log line where the Electron version also asserts persisted state. This plan closes the gaps that are worth closing, and records the ones that are deliberately platform-specific. Every new test must follow the existing conventions of the suite it is added to: same directory layout (`<n>-<name>/test.sh`), same helper functions from that suite's `lib/common.sh`, same header comment style, same numbering, and the same scheduling markers.

## Gap analysis

### In mobile, missing from Electron

| Mobile test | Action |
| --- | --- |
| `0-launch-and-navigate` | Skip. Every Electron test starts the app and navigates, so a dedicated test adds nothing. |
| `9-share-roundtrip` | Skip. Covered on desktop by `cli-desktop-lan-share-smoke-tests.sh`. |
| `21-import-video` | **Add.** Electron has no video import test, so the ffprobe/ffmpeg path is untested through the app. |
| `26-receive-database` | Skip. Covered by `cli-desktop-lan-share-smoke-tests.sh` (CLI sender to desktop receiver). |
| `27-receive-secret` | Skip. Same as above. |
| `28-host-emulator-comms` | Skip. Emulator infrastructure only. |
| `29-stale-recent-database` | **Add.** Clicking a recent entry whose files are gone is a real desktop case and is untested. |
| `30-export-asset` | Skip. Covers a mobile share-sheet cancel that has no desktop analogue (desktop writes straight to disk, covered by 19/20). |
| `31-create-database-no-collision` | **Add.** As "creating a database into a non-empty folder is rejected", which is the shared behaviour underneath. |
| `32-encrypted-database` | **Add.** The CLI encrypted suite covers the CLI; nothing opens an encrypted database through the desktop app. |
| `33-s3-database` | **Add,** opt-in on `TEST_S3_BUCKET` and skipping cleanly when unset, exactly as the mobile test does. |
| `34-sync` | **Add.** Electron's `24-sync-settings` covers the gate and persistence, not an actual sync run. |
| `35-database-summary` | **Add.** No desktop coverage of the database summary page. |
| `36-prefetch-database` | **Add.** No desktop coverage of prefetch into a partial replica. |
| `37-lan-share-timeout` | Skip. It exists to catch the mobile embedded-engine virtual clock racing ahead; desktop uses real timers, and the test costs a real 60 seconds. |
| `39-secret-in-keychain` | Skip. Desktop keychain storage is covered by `apps/cli/smoke-tests-key-chain`. |

### In Electron, missing from mobile

| Electron test | Action |
| --- | --- |
| `23-developer-screen` | **Add** as mobile `23-developer-screen`, minus the Electron-only DevTools toggle section. |
| `24-sync-settings` | **Add** as mobile `24-sync-settings`. The Configuration dialog and both toggles live in shared `packages/user-interface`. |

### Same number, weaker mobile version

These already exist on both sides but the mobile port only waits for a log line. Each needs the assertion the Electron version makes, using the mobile suite's `read_value` / `assert_value` / `wait_for_value` helpers and device-side reads rather than host file reads.

- `11-edit-encryption-key`, `12-edit-api-key`, `13-edit-s3-credentials`, `14-rename-secret` - assert the secret's persisted value and type round-trip unchanged after the edit.
- `15-duplicate-name` - assert the original secret is left untouched, and add the missing `check_no_errors` (allowing the expected duplicate-name error, as the Electron version does).
- `16-remove-recent-database` - assert the entry is actually gone from the recent list.
- `17-news-notifications` - extend to the full lifecycle the Electron version covers: two items, dismissal persists only the dismissed one, a restart shows the second, a third start shows none.
- `19-download-single-asset`, `20-download-multiple-assets` - assert the exported file(s) exist on the device with the expected content, not just that a completion line was logged.

## Issues

## Steps

Each step is complete when `bun run compile` is clean, the unit tests pass (`bun run test`), and the specific smoke test added or changed passes on its own (`bun run test:electron -- <n>` for Electron, `bun run test:and -- <n>` for mobile). New Electron tests keep the same number as their mobile counterpart so a number identifies the same test in both suites.

1. Add `apps/desktop/smoke-tests/21-import-video/test.sh`, porting mobile `21-import-video`: import `test/multiple-files/test.mp4` through the import UI and assert it lands in the gallery.
2. Add `apps/desktop/smoke-tests/29-stale-recent-database/test.sh`, porting mobile `29-stale-recent-database`: open a real database, click a recent entry whose directory does not exist, assert the "Database not found" warning fires and the open database is untouched.
3. Add `apps/desktop/smoke-tests/31-create-database-no-collision/test.sh`: create two databases in a row, each into its own folder, and assert both succeed; then assert creating into an existing non-empty database folder is rejected.
4. Add `apps/desktop/smoke-tests/32-encrypted-database/test.sh`, porting mobile `32-encrypted-database`: create and encrypt a database with the CLI, store the private key as an `encryption-key` secret, open it in the app, assert the gallery loads decrypted assets.
5. Add `apps/desktop/smoke-tests/33-s3-database/test.sh`, porting mobile `33-s3-database`: opt in on `TEST_S3_BUCKET`, log a skip line and exit 0 when unset. Cover the same three cases (a populated bucket lists, a bad credential surfaces an error rather than an empty list, a bad certificate fails closed).
6. Add `apps/desktop/smoke-tests/34-sync/test.sh`, porting mobile `34-sync`: make an edit, assert the sync runs start to finish and the navbar spinner appears then clears.
7. Add `apps/desktop/smoke-tests/35-database-summary/test.sh`, porting mobile `35-database-summary`: open a seeded database, navigate to the database summary page, assert it loads with data.
8. Add `apps/desktop/smoke-tests/36-prefetch-database/test.sh`, porting mobile `36-prefetch-database`: partially replicate a database, open the partial replica, assert the prefetch copies the missing thumbnails in.
9. Add `apps/smoke-tests/tests/23-developer-screen/test.sh`, porting Electron `23-developer-screen`: enable developer mode by tapping the About version label, open the developer screen, open and leave Stories, toggle the FPS indicator on and off. Omit the DevTools toggle (Electron only).
10. Add `apps/smoke-tests/tests/24-sync-settings/test.sh`, porting Electron `24-sync-settings`: toggle "Enable syncing" and "Only sync over Wi-Fi", assert each recomputes the sync gate and that both values persist across a restart. Persistence is read back device-side, not from a host TOML file.
11. Strengthen mobile `11-edit-encryption-key`, `12-edit-api-key`, `13-edit-s3-credentials` and `14-rename-secret`: assert the persisted value and type after the edit.
12. Strengthen mobile `15-duplicate-name`: assert the original secret is unchanged and add `check_no_errors` with the expected duplicate-name error filtered out.
13. Strengthen mobile `16-remove-recent-database`: assert the removed entry is gone from the recent list.
14. Extend mobile `17-news-notifications` to the full multi-item, dismissal-persistence and restart lifecycle the Electron test covers.
15. Strengthen mobile `19-download-single-asset` and `20-download-multiple-assets`: assert the exported files exist on the device with the expected content.
16. Add the scheduling markers each new test needs: `.sequential` in the Electron suite and `.exclusive` / `.slow` in the mobile suite, following the rules in `apps/smoke-tests/tests/README.md`. None of the new tests puts a LAN-share peer on the network, so this is expected to be limited to marking the slower new Electron tests (32, 33, 36) as `.sequential` if they prove unstable in a parallel batch.
17. Update the docs: the test count and numbering note in `docs/testing/README.md`, and the marker list in `apps/smoke-tests/tests/README.md` if step 16 added any.

## Unit Tests

No new or changed TypeScript functions. All the work is shell smoke tests plus, if a new `data-id` or test-driver command turns out to be missing while writing a test, the corresponding addition in `packages/user-interface/src/lib/test-driver.ts`. If a step adds or changes a function there, that step must also add a unit test for it under `packages/user-interface/src/test/`.

## Smoke Tests

The plan is entirely smoke tests. The full list is the eight new Electron tests (steps 1-8), the two new mobile tests (steps 9-10), and the seven strengthened mobile tests (steps 11-15).

## Verify

- `bun run compile` is clean.
- `bun run test` passes.
- `bun run test:electron` passes, including the eight new tests.
- `bun run test:and` passes, including the two new tests and the strengthened ones.
- `bun run test:ios` passes if a macOS machine is available; the mobile tests are platform-neutral so no iOS-specific work is expected.
- The S3 test skips cleanly with a logged skip line when `TEST_S3_BUCKET` is unset.

## Notes

- Numbering: mobile 0-24 mirrors the Electron suite, 25+ is mobile-only. Adding the Electron ports under their existing mobile numbers (29, 31-36) breaks that "25+ means mobile-only" statement, so `apps/smoke-tests/tests/README.md` needs its wording updated. Matching numbers across suites is worth more than the old rule.
- Both runners discover tests by scanning directories and sorting, so gaps in the numbering are fine.
- Mobile tests are far shorter than their Electron counterparts largely because `apps/smoke-tests/lib/common.sh` has more helpers (`create_database`, `add_secret_via_ui`, `run_cli`, `assert_value`) while the Electron tests inline their cleanup and use `python3` for host file assertions. Do not treat the length difference itself as the gap; the gap is the missing assertions listed above.
- The seven strengthened mobile tests may need new test-driver read commands to see persisted state on device. Prefer reusing `get-value` / `get-storage` before adding anything new, and never add a platform-specific channel for this.
- `30-export-asset` and `37-lan-share-timeout` are deliberately mobile-only. If someone later asks why Electron lacks them, this plan is the record.
