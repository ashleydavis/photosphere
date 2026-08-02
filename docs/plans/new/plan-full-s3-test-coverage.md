# Full S3 smoke-test coverage across CLI, desktop and mobile

## Overview

Photosphere supports S3-backed databases on every platform, but the automated coverage of that support is a single test per platform and two of the three never open a database at all. `apps/cli/smoke-tests/65-s3-database` runs `init`, `add`, `summary` and `list` against a local MinIO with credentials from `AWS_*` environment variables. `apps/desktop/smoke-tests/25-s3-database` and `apps/smoke-tests/tests/40-s3-database` both only browse a seeded bucket from the New/Add Database dialog and then cancel, so no desktop or mobile code path ever writes a byte to S3 in a test. On mobile that means the only S3 call ever made inside the embedded JS engine is the `ListObjectsV2` behind the `list-s3-dirs` task. Everything else the app can do on S3 (replicate, sync, verify, repair, encrypt, export, prefetch, write locks, paged listings) is tested only against the local filesystem, and the one piece of bespoke S3 code with no coverage whatsoever is the write-lock implementation in `packages/storage/src/lib/cloud-storage.ts` (lines 512-730), whose only test path is `apps/cli/write-lock-smoke-test.sh --cloud`, which requires a real AWS bucket named `photosphere-test-write-lock` plus the AWS CLI and so has never run here.

This plan adds S3 coverage for every feature that already has local-database coverage, on all three platforms, driven by the existing local MinIO emulator (`scripts/s3-emulator.sh`) so no test needs credentials, an account, or the network, and no test can skip.

The instruction from the user governs the whole plan: **when a new test fails because the application is broken, do not change the application to make it pass.** Leave the test failing, record what is broken and where, and move on. The final step of the plan is a report of the state of every test.

## Issues

## Steps

### Step 1: Shared S3 emulator helpers for the three suites

Each S3 test currently repeats the same twenty lines: make a state directory, `bun run s3-emulator start`, source the env file, build the endpoint, and add an emulator stop to the trap. With a dozen more S3 tests coming, factor it out once per suite.

1. In `apps/cli/smoke-tests/lib/common.sh` add:
   - `start_s3_emulator <state-dir>`: creates the directory, runs `bun run s3-emulator start` from the repo root, sources `<state-dir>/env`, and exports `S3_ENDPOINT` as `http://127.0.0.1:$S3_EMULATOR_PORT`. Fails loudly (calls `log_error` and `exit 1`) when the emulator does not start.
   - `stop_s3_emulator <state-dir>`: wraps `bun run s3-emulator stop`, never fails, safe in a trap.
   - `export_s3_env_credentials`: exports `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT` and `AWS_REGION` from the emulator's values, for the tests that use the environment-variable credential path.
   - `seed_s3_vault_secret <secret-name>`: builds the `s3-credentials` JSON from the emulator's values and writes it with the existing `seed_vault_secret`, for the tests that use the vault credential path.
2. In `apps/desktop/smoke-tests/lib/common.sh` add `start_s3_emulator` / `stop_s3_emulator` with the same contract, plus `add_s3_secret_via_ui <port> <name> <endpoint> <region> <access-key> <secret-key>` that drives the Add Secret dialog field by field (the existing `add_secret_via_ui` only fills the region, which is not enough for a real connection). Lift the field sequence verbatim from `apps/desktop/smoke-tests/25-s3-database/test.sh` lines 58-68.
3. In `apps/smoke-tests/lib/common.sh` add the same three helpers for mobile, with the endpoint built from `"${PLATFORM}_host_address"` rather than loopback, lifting the sequence from `apps/smoke-tests/tests/40-s3-database/test.sh` lines 39-69.
4. Rewrite the three existing S3 tests (CLI 65, desktop 25, mobile 40) to use the new helpers. Their assertions must not change: run all three before and after and confirm the same passes.

Complete when: `bun run test:cli -- 65`, `bun run test:electron` (test 25) and `bun run test:and 40` behave exactly as they did before the refactor.

### Step 2: An S3 object helper script for the tests that need to touch the bucket directly

Several tests below need to inspect or damage the bucket from shell: count objects under a prefix, delete one object, overwrite one object, and seed more than 1000 objects. Shell cannot sign S3 requests, and `jq`/`aws` are not declared dependencies of this repository, so this is the case `CLAUDE.md` describes where a real TypeScript helper under `scripts/` is the answer.

1. Create `scripts/s3-object.ts` with the comment block and argument style of `scripts/seed-s3-bucket.ts` (which it should be read alongside). Options: `--endpoint`, `--bucket`, `--access-key`, `--secret-key`, and one of the subcommands:
   - `count --prefix <p>`: prints the number of objects under the prefix, following continuation tokens to the end.
   - `list --prefix <p>`: prints one key per line.
   - `put --key <k> --body <string>`: writes an object.
   - `delete --key <k>`: deletes one object.
   - `seed-many --prefix <p> --count <n>`: writes `n` small objects under the prefix, with bounded concurrency, for the paging test.
   All of it uses `@aws-sdk/client-s3` with `forcePathStyle: true`, exactly as `seed-s3-bucket.ts` does. No new dependency.
2. Do not delete or edit `scripts/clear-s3-bucket.js` or `run-cloud-storage-tests.sh`. Both are superseded by this work (`clear-s3-bucket.js` is JavaScript, which the repository's language rule bans, and both target a real AWS bucket and clear it), but deleting files is the user's call. Report them at the end of the run as candidates for removal.
3. `bun run compile` must pass with the new script in the tree.

Complete when: the four subcommands each produce correct output when run by hand against an emulator started with `bun run s3-emulator start`, and `bun run compile` passes.

### Step 3: CLI 66 — S3 credentials from a vault secret

New directory `apps/cli/smoke-tests/66-s3-vault-credentials/test.sh`, `DESCRIPTION="S3 database using credentials from a vault secret"`.

Covers `resolveStorageCredentials`' vault branch (`packages/node-api/src/lib/resolve-storage-credentials.ts` lines 63-83), which is the branch desktop and mobile actually use and which no test exercises today. The environment-variable branch is already covered by test 65.

The test: start the emulator; write an `s3-credentials` secret with `seed_s3_vault_secret`; register the database with `dbs add --yes --name s3-db --path s3:<bucket>/vault-cred-test --s3-cred <secret>`; then run `init`, `add`, `summary` and `list` addressing the database **by name** (`--db s3-db`) with no `AWS_*` variables exported at all. Assert the imported file is listed. Then unset the secret's access key (edit it via `secrets edit --yes --value ...` to a wrong value) and assert a subsequent `list` exits non-zero rather than reporting an empty database.

Note for the implementing agent: `resolveStorageCredentials` matches the databases.json entry on an exact `path` string, so the path registered with `dbs add` must be byte-identical to the one later used.

Complete when: the test has been watched failing first (break it by pointing `--s3-cred` at a non-existent secret and confirm it goes red), then run for real, and its outcome recorded.

### Step 4: CLI 67 — replicate between local and S3, both directions

New directory `apps/cli/smoke-tests/67-s3-replicate/test.sh`.

Build a local database with `populate_db_with_5_files`, replicate it to `s3:<bucket>/replica`, and assert: replication reports success; `root-hash --db` on the source and on the S3 replica match; `database-id` matches; `summary` on the replica reports the same file count. Then replicate the S3 database back down to a second local directory and assert the same three things again. Then add one more file to the source, replicate again, and assert the replica picks up exactly the new file.

The existing helpers in `apps/cli/smoke-tests/lib/functions.sh` (`test_database_replicate` and friends) cannot be reused: they hardcode `$TEST_DB_DIR`, `rm -rf` the destination, and assert with `check_exists` on filesystem paths. This test asserts through CLI output and `root-hash` only.

Complete when: watched failing first (assert a deliberately wrong file count), then run for real, outcome recorded.

### Step 5: CLI 68 — encrypted database on S3

New directory `apps/cli/smoke-tests/68-s3-encrypted/test.sh`.

Covers `EncryptedStorage` wrapped around `CloudStorage`, which no test exercises: the encrypted suite (`apps/cli/smoke-tests-encrypted.sh`) is filesystem-only.

`init --db s3:<bucket>/encrypted --key <name> --generate-key --yes`, add a JPG and an MP4, `list` and `summary` read them back, `verify` passes. Then use `scripts/s3-object.ts list` to confirm the asset objects exist in the bucket, and `get` one asset object and assert its bytes are **not** the plaintext of the source file (that is what proves the encryption layer is actually in the path over S3, not just over the filesystem). Finally, run `list` with the key removed from the vault and assert a loud failure.

Complete when: watched failing first, run for real, outcome recorded.

### Step 6: CLI 69 — sync between an S3 database and a local copy

New directory `apps/cli/smoke-tests/69-s3-sync/test.sh`.

Mirrors the local sync tests 35-40 with an S3 endpoint on one side: replicate a local database to S3 to create the pair, then in turn sync original→copy, copy→original, an edited field each way, and a deleted asset each way, asserting the root hashes converge after each sync. Use `sync --db <a> --dest <b> --yes` as tests 35-40 do.

Complete when: watched failing first, run for real, outcome recorded.

### Step 7: CLI 70 — verify, repair and orphan handling on S3

New directory `apps/cli/smoke-tests/70-s3-verify-repair/test.sh`.

On an S3 database populated with the five standard files: `verify` passes, `verify --full` passes. Then delete one asset object from the bucket with `scripts/s3-object.ts delete` and assert `verify` reports the missing file and exits non-zero. Then overwrite one asset object with different bytes via `put` and assert `verify --full` reports it as modified. Then repair from a good local replica and assert `verify` passes again. Finish with `find-orphans` on a bucket where an extra unreferenced object has been put, asserting it is reported.

This is the S3 counterpart of local tests 15, 16, 24 and 26.

Complete when: watched failing first, run for real, outcome recorded.

### Step 8: CLI 71 — export from S3 and byte-exact round trip

New directory `apps/cli/smoke-tests/71-s3-export/test.sh`.

Add `test/test.jpg` and `test/multiple-files/test.mp4` to an S3 database, export both back to a local directory with the `export` command, and compare each exported file to its source with `cmp`. A byte-exact match is what proves `readStream` (which always goes through `S3RangeReadableStream`, see `packages/storage/src/lib/cloud-storage.ts` line 379) returns the whole object and not a truncated first chunk.

Note: the multipart-upload path (`Upload` with a 100 MB `partSize`) and the multi-chunk range path (chunk sizes start at 100 MB) only engage on files above 100 MB. Generating such a fixture is out of scope here; this test covers the single-chunk path only, and the plan records the >100 MB path as knowingly uncovered.

Complete when: watched failing first, run for real, outcome recorded.

### Step 9: CLI 72 — S3 path shapes

New directory `apps/cli/smoke-tests/72-s3-paths/test.sh`.

Four databases in one bucket, each fully created and read back, asserting they do not see each other's assets:
- `s3:<bucket>/simple`
- `s3:<bucket>/a/b/c/deep` (a deep prefix)
- `s3:<bucket>:/colon-form` (the `s3:bucket:/prefix` form the S3 browser produces in `packages/user-interface/src/components/s3-browser-modal.tsx` line 111, which the app writes into `databases.json` but which no CLI test has ever used)
- a database whose asset filenames contain a space and a non-ASCII character

Complete when: watched failing first, run for real, outcome recorded.

### Step 10: CLI 73 — listing pagination past the first page

New directory `apps/cli/smoke-tests/73-s3-pagination/test.sh`.

Seed 1,100 objects under one prefix with `scripts/s3-object.ts seed-many`, then assert `scripts/s3-object.ts count` returns 1,100, which is the direct check that the `ContinuationToken` branches of `CloudStorage.listFiles` and `listDirs` (lines 114-224) enumerate past the first 1000-key page. Then build a database of more than 1000 assets is **not** attempted (too slow); instead assert the app-level listing over a large prefix by running `find-orphans` against that prefix and confirming it reports 1,100 unreferenced objects rather than 1,000.

If seeding 1,100 objects takes more than about 90 seconds against local MinIO, reduce the count to 1,050 (still past one page) and say so in the report rather than dropping the test.

Complete when: watched failing first (assert 1,000 and confirm it goes red), run for real, outcome recorded.

### Step 11: CLI 74 — loud failure when S3 is unavailable

New directory `apps/cli/smoke-tests/74-s3-failures/test.sh`.

Three assertions, each of which must produce a non-zero exit and an error message, never an empty-but-successful result:
1. Endpoint dead: create and populate an S3 database, `stop_s3_emulator`, then run `list` and `summary`.
2. Wrong bucket: run `summary` against `s3:no-such-bucket/db` on a live emulator.
3. Endpoint dies mid-import: start an `add` of the `test/multiple-files` directory and stop the emulator while it runs; assert the command fails rather than reporting a successful partial import.

Assertion 3 is the one that matters most: a silent partial success here is how a backup ends up incomplete.

Complete when: watched failing first, run for real, outcome recorded.

### Step 12: CLI 75 — the CloudStorage API integration test, against MinIO

`packages/storage/integration-tests/cloud-storage.test.ts` already covers the whole `CloudStorage` surface in 561 lines (basic file ops, directory ops, streams, the full write-lock lifecycle, error handling, path handling) but has never run in CI: it needs `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `TEST_S3_BUCKET`, and `packages/storage/jest.config.js` excludes `integration-tests` from the normal run. Point it at the emulator instead of deleting the value in it.

1. Add `packages/storage/jest.integration.config.js`: the same `ts-jest` preset, `roots` limited to `integration-tests`, and no `modulePathIgnorePatterns` entry for it.
2. Add a `test:integration` script to `packages/storage/package.json` running `jest -c jest.integration.config.js`. Do **not** add it to the package's `test` script: without an emulator it must not run at all, and the smoke test below is what provides one.
3. New directory `apps/cli/smoke-tests/75-s3-storage-api/test.sh`: starts the emulator, exports `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `AWS_ENDPOINT` and `TEST_S3_BUCKET`, and runs `bun run --filter=storage test:integration`. The suite's pass/fail is the test's pass/fail.
4. Run it first unmodified. `CloudStorage`'s constructor reads `AWS_ENDPOINT` from the environment (line 55) but takes credentials only when passed explicitly, so the credentials reach it through the AWS SDK's own environment provider. If that does not work against MinIO, change the test file's `beforeAll` to construct `new CloudStorage(location, {...})` with credentials read from the same environment variables. That is a change to a test file, not to app code, and is allowed.
5. While editing that file, rename its `it(` calls to `test(` per the repository style rule.

Complete when: the suite runs to completion against MinIO and every test's result (pass or fail) is recorded. Any failure here is a real finding about `CloudStorage` and must be reported, not fixed.

### Step 13: CLI 76 — write locks on S3 under contention

New directory `apps/cli/smoke-tests/76-s3-write-locks/test.sh`.

`CloudStorage.acquireWriteLock` / `refreshWriteLock` / `releaseWriteLock` (lines 547-730) implement mutual exclusion on a store that has no native locking primitive, and nothing tests them under contention. Follow the shape of `apps/cli/write-lock-smoke-test.sh`: N concurrent CLI processes (start with 4) each performing several `add` operations against the same S3 database, each writing its output to its own file under the test's `tmp/`; then assert every process exited zero, the database verifies, and the asset count equals the total number of adds (no lost update).

Do not modify `apps/cli/write-lock-smoke-test.sh` and do not use its `--cloud` mode: that mode names a real AWS bucket and is not something a test here should touch.

Complete when: watched failing first, run for real, outcome recorded. If the locking is genuinely broken this test stays red and is reported.

### Step 14: Desktop 26 — full S3 database lifecycle through the UI

New directory `apps/desktop/smoke-tests/26-s3-database-lifecycle/test.sh`.

Today desktop S3 support is proven only as far as listing a bucket. This creates a database on S3 through the app and uses it:

1. Start the emulator; start the app; add the S3 credentials through the Add Secret dialog with the new `add_s3_secret_via_ui` helper.
2. Open the New Database dialog from the `new-database` menu item, set the type to S3 (`database-storage-type-select` then `database-storage-type-option-s3`), pick the secret (`select-s3-button` then `secret-select-button`, waiting on `chosen-s3-secret`), type `s3:<bucket>:/desktop-lifecycle` into `database-path-input`, and click `create-database-confirm`. Wait for the `Database created` log line.
3. Import two fixtures from `test/multiple-files` through the import page (`import-button`, `import-drop-zone` drop, wait for `2 assets imported`) exactly as `apps/desktop/smoke-tests/4-import-photos/test.sh` does.
4. Navigate to the gallery and wait for `Gallery loaded: 2 assets`.
5. Open the Database Info page and assert it loads and reports the database.
6. Restart the app, reopen the same database from the Manage Databases page, and assert the gallery again loads 2 assets: that is what proves the data came out of the bucket and not from an in-process cache.
7. `check_no_errors "$TMP_DIR"` with no allowances.

All element ids named above were read from `packages/user-interface/src/components/create-database-modal.tsx` and the existing desktop tests; none are invented. Any id that turns out not to exist is a finding to report, not something to work around.

Complete when: watched failing first (point the path at a bucket that does not exist and confirm it goes red), run for real, outcome recorded.

### Step 15: Desktop 27 — replicate a local database to an S3 destination

New directory `apps/desktop/smoke-tests/27-s3-replicate/test.sh`, following `apps/desktop/smoke-tests/17-replicate-database/test.sh` but with an S3 destination, then opening the replica and asserting its gallery loads the source's asset count.

**This step needs an application change and must be raised with the user before it is made.** `packages/user-interface/src/components/replicate-database-dialog.tsx` has no `data-id` on its "Destination type" `Select` or its `S3` `Option`, and `packages/user-interface/src/components/configure-secrets-modal.tsx` has no `data-id` on any of its selects, options, or its Save button. Without those the destination cannot be switched to S3 from a test. The change needed is the addition of `data-id` attributes only, in the same style as every other dialog in that package (for example `replicate-dest-type-select`, `replicate-dest-type-option-s3`, `configure-secrets-s3-select`, `configure-secrets-save`). It is not a behaviour change and not a bug fix, but it is app code, so the agent asks first, and if the user declines, this step is dropped and recorded as not covered.

Complete when: either the test runs and its outcome is recorded, or the user has declined the `data-id` additions and the gap is recorded.

### Step 16: Desktop 28 — S3 failure surfaces in the UI

New directory `apps/desktop/smoke-tests/28-s3-failure/test.sh`.

Create and populate an S3 database as in step 14, stop the emulator, then reopen the database in the app and assert the app reports an error rather than presenting an empty gallery. An empty gallery for an unreachable bucket is indistinguishable from an empty database, which is the same class of fault desktop test 25 already guards against for the bucket browser.

The error is provoked deliberately, so `check_no_errors` takes an allowance naming the expected message, as test 25 does on line 158.

Complete when: watched failing first, run for real, outcome recorded.

### Step 17: Mobile 41 — full S3 database lifecycle through the UI

New directory `apps/smoke-tests/tests/41-s3-database-lifecycle/test.sh`, the mobile counterpart of step 14.

This is the highest-value test in the plan: `mobile-worker-entry.ts` registers `create-database`, `import-assets`, `save-asset`, `load-assets`, `get-database-summary`, `sync-database` and `prefetch-database`, all of which reach storage through `openStorage`, and none of them has ever run against an `s3:` path inside QuickJS or JavaScriptCore. Only `list-s3-dirs` has. Whether the AWS SDK's `GetObject`/`PutObject` path works in the embedded engine is genuinely unknown, and this test is what answers it.

Structure: reset app state, start the app, start the emulator, add the S3 credentials through the Add Secret dialog with the endpoint from `"${PLATFORM}_host_address"`, create the database at `s3:<bucket>:/mobile-lifecycle` through the Create Database dialog, import the two fixtures through the `pick-files` + `import-files-button` path used by `apps/smoke-tests/tests/4-import-photos/test.sh`, and assert `Gallery loaded: 2 assets`.

Note for the implementing agent: the native `PathSandbox` restricts filesystem paths to the app's storage root. An `s3:` path is not a filesystem path and branches earlier in `createStorage`, but if the sandbox rejects it anyway that is a finding about the app, to be reported and left failing.

Complete when: watched failing first, run for real on Android, outcome recorded. iOS cannot be run from this machine (it needs the macOS/Xcode environment described in `CLAUDE.md`); the test is platform-neutral like every other test in that directory, and the report must say plainly that the iOS run was not performed.

### Step 18: Mobile 42 — sync and prefetch against an S3 origin

New directory `apps/smoke-tests/tests/42-s3-sync-prefetch/test.sh`.

Following `apps/smoke-tests/tests/34-sync/test.sh` and `36-prefetch-database/test.sh`, but with the origin database on S3 rather than a second on-device database: seed a local database whose `.db/config.json` origin points at the S3 path, open it, trigger an edit, and assert the sync runs start to finish; then open a partial replica of the S3 database and assert prefetch copies the missing thumbnails.

Complete when: watched failing first, run for real on Android, outcome recorded, iOS stated as not run.

### Step 19: Mobile 43 — S3 failure surfaces in the app

New directory `apps/smoke-tests/tests/43-s3-failure/test.sh`, the mobile counterpart of step 16: with the emulator stopped, opening the S3 database must surface an error rather than an empty gallery.

Complete when: watched failing first, run for real on Android, outcome recorded, iOS stated as not run.

### Step 20: Run everything and report

1. `bun run compile`.
2. `bun run test`.
3. `bun run test:cli` (the whole suite, not just the new tests, to prove nothing regressed).
4. `bun run test:electron`.
5. `bun run test:and`.
6. `bun run test:everything -- --force` last, as the canonical check.
7. Produce the report described under "Reporting" below.

Complete when: the report exists and every new test appears in it with a definite state.

## Reporting

The user's instruction is that a test failing because of an application defect stays failing. The final message of the implementation run must therefore list, for **every** test added or changed by this plan:

- The test's path and what it covers.
- Its state: passed, failed, or not run.
- For a failure: the exact assertion that failed, the command output, and the application code path responsible, named by file and line. A failure with no identified cause is reported as "cause not established", never as a guess.
- For "not run": why (iOS needs the macOS environment; anything else that could not be provisioned).
- Whether the test was watched failing first, as `CLAUDE.md` requires. A test that was never seen red is reported as unproven.

Also report: `scripts/clear-s3-bucket.js` and `run-cloud-storage-tests.sh` as superseded and awaiting the user's decision on removal, and the >100 MB multipart/multi-chunk paths as knowingly uncovered.

## Unit Tests

There is almost nothing here that a unit test can reach: every item in this plan is a shell smoke test, and the repository does not unit-test shell.

- `scripts/s3-object.ts` (step 2): `scripts/` is not a workspace package, so `bun run test` (which is `bun --filter '*' test`) does not cover it and there is no harness to add a unit test to without inventing one. It is exercised directly by the tests in steps 7, 9, 10 and 5, each of which fails if the helper is wrong. This is stated plainly rather than papered over.
- `packages/storage/integration-tests/cloud-storage.test.ts` (step 12) is itself the test; it needs no test.
- The `data-id` attributes in step 15 are React component markup, which this repository does not unit-test; they are covered by the smoke test that uses them.

No production TypeScript is added or changed by this plan, so there is no new function anywhere that requires a unit test.

## Smoke Tests

New:

- `apps/cli/smoke-tests/66-s3-vault-credentials` — S3 credentials from a vault secret, and a loud failure on a bad one.
- `apps/cli/smoke-tests/67-s3-replicate` — replicate local→S3 and S3→local, hashes and ids match, incremental re-replication.
- `apps/cli/smoke-tests/68-s3-encrypted` — encrypted database on S3, ciphertext in the bucket, loud failure without the key.
- `apps/cli/smoke-tests/69-s3-sync` — sync S3↔local both ways, field edits and deletions.
- `apps/cli/smoke-tests/70-s3-verify-repair` — verify, verify --full, deleted object, modified object, repair, orphans.
- `apps/cli/smoke-tests/71-s3-export` — byte-exact export of an image and a video out of S3.
- `apps/cli/smoke-tests/72-s3-paths` — simple, deep, `bucket:/prefix` and awkwardly named paths.
- `apps/cli/smoke-tests/73-s3-pagination` — more than one listing page.
- `apps/cli/smoke-tests/74-s3-failures` — dead endpoint, wrong bucket, endpoint lost mid-import.
- `apps/cli/smoke-tests/75-s3-storage-api` — the full `CloudStorage` API integration suite against MinIO.
- `apps/cli/smoke-tests/76-s3-write-locks` — concurrent writers against one S3 database.
- `apps/desktop/smoke-tests/26-s3-database-lifecycle` — create, import, view, restart, reopen on S3.
- `apps/desktop/smoke-tests/27-s3-replicate` — replicate to an S3 destination through the dialog (subject to step 15's approval).
- `apps/desktop/smoke-tests/28-s3-failure` — an unreachable bucket shows an error, not an empty gallery.
- `apps/smoke-tests/tests/41-s3-database-lifecycle` — the same lifecycle on Android/iOS, through the embedded worker.
- `apps/smoke-tests/tests/42-s3-sync-prefetch` — sync and prefetch against an S3 origin on device.
- `apps/smoke-tests/tests/43-s3-failure` — an unreachable bucket shows an error on device.

Changed: `apps/cli/smoke-tests/65-s3-database`, `apps/desktop/smoke-tests/25-s3-database`, `apps/smoke-tests/tests/40-s3-database` are refactored onto the shared helpers in step 1 with no change to what they assert.

## Verify

- `bun run compile` passes.
- `bun run test` passes (unchanged by this plan; run to prove no regression).
- `bun run test:cli` runs the whole CLI suite including the eleven new tests.
- `bun run test:electron` runs the desktop suite including the new tests.
- `bun run test:and` runs the mobile suite on Android including the new tests.
- `bun run test:everything -- --force` is run last as the canonical check.
- Every new test has been watched failing before being accepted, per `CLAUDE.md`.
- The report in step 20 exists and accounts for every test.

Expected outcome: some of these will fail. That is the point of writing them. A run in which every new test passes on the first attempt should itself be treated as suspicious and the "watched failing first" evidence re-checked.

## Notes

- `scripts/test-everything-parallel.sh` is frozen (`CLAUDE.md`) and hardcodes its suite list at line 46 (`compile test test:cli test:electron` plus the platform scripts). A brand-new top-level suite would therefore never run under `bun run test:everything`. That is why every test in this plan is a numbered directory inside an existing suite, and why the `CloudStorage` integration suite is driven from a CLI smoke test rather than being wired in as its own script.
- No `what-changed.json` change is needed: `apps/cli`, `apps/desktop`, `apps/smoke-tests` and `packages` are already watched paths for the relevant targets, and `scripts` is in `alwaysPaths`.
- The CLI helper functions in `apps/cli/smoke-tests/lib/functions.sh` cannot be reused for S3 databases. They hardcode `$TEST_DB_DIR`, `rm -rf` their destinations, and assert with `check_exists`/`ls` against filesystem paths. Every S3 test asserts through CLI output, `root-hash`, `database-id` and `scripts/s3-object.ts` instead.
- The two path forms both occur in the wild and both must keep working: the CLI tests use `s3:bucket/prefix`, while the S3 browser writes `s3:bucket:/prefix` into `databases.json` (`s3-browser-modal.tsx` line 111, and `apps/cli/smoke-tests-lan-share.sh` line 238 uses that form too). Step 9 covers both.
- Tests must address the emulator by IP (`127.0.0.1` on desktop/CLI, `"${PLATFORM}_host_address"` on mobile), never `localhost`. The existing tests' header comments explain why, and `CloudStorage` does not set `forcePathStyle`, so the addressing style is decided by the SDK from the endpoint.
- MinIO's binary is cached under `.s3-emulator-cache`, but each test still starts its own server on an OS-assigned port. Seventeen S3 tests across three suites, several running in parallel, means several MinIO processes at once. If that turns out to be a resource problem on this machine, report it rather than silently serialising the suites.
- The >100 MB paths (`Upload` with a 100 MB `partSize` in `writeStream`, and the 100/20/10 MB chunk ladder in `S3RangeReadableStream`) are not covered: triggering them needs a fixture larger than 100 MB. This is recorded as a known gap rather than attempted.
- `jq` is present on this machine but is not declared in `mise.toml` and must not be used by any of these tests. `scripts/s3-object.ts` exists precisely so no test needs it.
- The write-lock coverage in step 13 and the `CloudStorage` API coverage in step 12 are the two places most likely to turn up real defects, because both target code that has never executed under test. Neither may be "fixed" during this work.
