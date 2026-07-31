# S3 smoke tests against a local MinIO server

## Overview

There is no S3 smoke test on either platform. The mobile one, `apps/smoke-tests/tests/33-s3-database/test.sh`, has been deleted. It opened with a `TEST_S3_BUCKET` guard and exited successfully when it was unset, so it never ran in a normal `bun run test:and` and reported a pass while asserting nothing. When it was finally forced to run it turned out to be driving a screen that does not exist: it typed into `s3-browser-bucket-input`, clicked `s3-browser-list-button` and waited on `s3-browser-dir-0`, none of which appear anywhere in the codebase, and it navigated to an `/s3-browser` route that was never built. The desktop suite has no S3 test at all. That gap let real faults sit in the S3 code path unnoticed.

This plan provisions the infrastructure locally instead of asking for credentials: a cached MinIO binary started by the test itself on a free port over plain HTTP, seeded through the S3 API. The test then needs nothing configured, runs on every machine, and can never skip. The same test exists on desktop and mobile and asserts the same things.

**This plan runs only after the mobile worker has been converted to the real AWS SDK** and `packages/mobile-worker/src/shims/aws-s3.ts` has been deleted (see `plan-remove-hand-written-s3-client.md`). The hand-written client ignored the URL scheme and always opened a TLS connection, which forced a certificate authority, a trust anchor and a TLS proxy into the repository purely to run one test. Plain HTTP against a local server is only viable once the real SDK, which honours `http://`, is in use. If step 1 finds the shim still present, stop.

## Issues

## Steps

Every step that changes code must leave `bun run compile` clean and `bun run test` passing before it is considered done.

### Step 1: Confirm the prerequisite

Verify the SDK conversion actually landed:

- `packages/mobile-worker/src/shims/aws-s3.ts` and `aws-lib-storage.ts` do not exist.
- `packages/mobile-worker/scripts/bundle.ts` (the build script moved into `scripts/`) aliases no `@aws-sdk/*` or `@smithy/*` module. Choosing between the node and browser variants the vendor already ships is not aliasing.
- The repository contains no certificate authority, TLS proxy, or Android trust anchor added for testing.

If any of these fail, stop and report. Do not work around a surviving hand-written client; this plan's plain-HTTP approach depends on the real SDK.

At the time of writing all three hold: the conversion landed, and the real SDK has been driven end to end from the Android worker against a local MinIO over plain HTTP. Re-check rather than assume.

### Step 2: Fix bucket-root listing in `packages/storage`

Opening the S3 browser asks to list the top of a bucket, which means a bucket name and an empty key. The private `parsePath` in `packages/storage/src/lib/cloud-storage.ts` rejects an empty key, so the request throws before it is ever sent and the browser fails the moment it opens, on every platform. `listFiles` and `listDirs` already contain branches handling `key === ""` and `key === "/"` that cannot currently be reached.

- Add `packages/storage/src/lib/s3-path.ts` exporting `parseS3ListPath(path: string): IS3PathParts`, splitting bucket from key and permitting an empty key, with a named `IS3PathParts` interface. Rejects an empty bucket.
- Change `listFiles` and `listDirs` in `cloud-storage.ts` to use it.
- Leave `parsePath` alone: naming a file must still require a file name, so an empty key there stays an error.

Confirm first that the SDK conversion did not already address this; if it did, skip the step and record that.

### Step 3: Fix addressing for endpoints that are an IP address or localhost

With a custom endpoint the SDK defaults to virtual-host addressing and builds a hostname like `photosphere-smoke-test.127.0.0.1`, which cannot resolve. Every self-hosted S3 target (MinIO, Ceph, and the emulator this plan starts) is unreachable as a result.

- Add `packages/storage/src/lib/s3-addressing.ts` exporting `requiresPathStyleAddressing(endpoint: string): boolean`, true for an IPv4 or IPv6 literal host, `localhost`, or `127.0.0.1`, false for a DNS name.
- In `cloud-storage.ts`, set `forcePathStyle` from it when building the client. Real provider endpoints must be unaffected.

This step is confirmed still needed after the SDK conversion. Driving the real SDK at a MinIO on `192.168.55.1` produced requests to `photosphere-adhoc.192.168.55.1`, which does not resolve. It was only reachable by giving the endpoint a hostname whose wildcard DNS resolved, which is not something a test or a user should have to do.

### Step 4: Add the MinIO runner script

Create `scripts/s3-emulator.sh` with `start <state-dir>` and `stop <state-dir>` subcommands. Requirements:

- Resolves the platform from `uname -s` / `uname -m` to a MinIO download for linux/darwin on amd64/arm64, and fails with a clear message on anything else.
- Downloads the pinned MinIO release once into a repo-level cache directory, to a `.partial` name moved into place only on success, so an interrupted download cannot leave a half-written binary that a later run treats as cached. Reuses the cached binary when present.
- Asks the OS for a free port rather than picking a number, so two suites starting at the same moment cannot collide.
- Serves **plain HTTP only**. No TLS, no certificates.
- Waits for `/minio/health/live` before returning, with a timeout, and prints the server log on failure.
- Seeds the bucket, then writes a shell-sourceable `env` file into the state directory exporting `S3_EMULATOR_PORT`, `S3_EMULATOR_BUCKET`, `S3_EMULATOR_ACCESS_KEY` and `S3_EMULATOR_SECRET_KEY`.
- `stop` terminates the server from the recorded pid and is safe to call when nothing is running, so it can go in a trap unconditionally.

Add `scripts/seed-s3-bucket.ts`, run by the script after the server is healthy, which creates the bucket and two directory prefixes through the S3 API so the browser has something to list. Bucket name, credentials and seeded prefixes are constants in the shell script and passed in.

Add the cache directory to the root `.gitignore`. Do not create a `.gitignore` inside `packages/` or `scripts/`.

### Step 5: Expose the runner through `package.json`

Add a script to the root `package.json` so nothing invokes the shell script directly, matching how `test:cli` and `test:electron` wrap their scripts. Tests call the wrapper.

### Step 6: Add the `data-id` attributes the tests need

The S3 browser and the New Database dialog have no way to be driven. Add attributes only, no behaviour change:

- `packages/user-interface/src/components/s3-browser-modal.tsx`: the bucket input, the error text, each listed directory (indexed), and the Cancel button.
- `packages/user-interface/src/components/create-database-modal.tsx`: the storage-type select button, the S3 option, the chosen-secret label and the select-secret button (both keyed by secret type), and the Cancel button.
- `packages/user-interface/src/components/add-database-modal.tsx`: the same set. This is the dialog the mobile flow opens, and only its confirm button, name and path inputs carry a `data-id` today; the storage-type select in particular has none, so S3 cannot be chosen from a test.

Only add these if step 8 chooses the browser-driving route. If the mobile test seeds `databases.toml` instead, the mobile half needs none of them and this step covers the desktop test alone.

These are React components, so they are covered by the smoke tests rather than unit tests.

### Step 7: Write the desktop test

Create `apps/desktop/smoke-tests/<next-number>-s3-database/test.sh`, numbered after the current highest in that directory. It must:

- Start the emulator into its own `tmp/s3` state directory and source the `env` file.
- Register a trap that stops both the app and the emulator, so a failure never leaves a server running.
- Add an `s3-credentials` secret through the app's own add-secret UI, with the endpoint pointing at the emulator, rather than writing the vault directly.
- Open the New Database dialog, choose the S3 storage type, select the secret, open the browser, and type the bucket name. The listing loads on the bucket field changing; there is no separate list button.
- Assert the seeded directories appear by name. Match on a prefix: the browser renders each entry with a trailing slash.
- Then edit the secret to bad keys through the edit-secret UI, browse again, and assert an error is shown rather than an empty list. An empty list is the failure this test exists to catch.
- On a failed assertion, log the browser's own error text. Without that the only evidence is an empty element.

### Step 8: Write the mobile test

Create `apps/smoke-tests/tests/<next-number>-s3-database/test.sh`. There is nothing to rewrite: the old file has been deleted, and none of it should be brought back. It carried a `TEST_S3_BUCKET` guard, an assertion about a bad server certificate failing closed that only ever tested the deleted client's TLS behaviour, and element ids for a screen that was never built.

**Drive only what exists.** Before writing a single `send_command`, open the component and read the `data-id` attributes off it. The mobile app has no `/s3-browser` route: the S3 browser is a modal (`packages/user-interface/src/components/s3-browser-modal.tsx`) reached from the add-database and create-database dialogs, and it has no `data-id` attributes until step 6 adds them.

Two routes are available, and the second is the one already proven to work:

- Drive the browser UI as the desktop test does, which requires step 6's attributes on the mobile-reachable dialog (`add-database-modal.tsx` as well as `create-database-modal.tsx`).
- Or skip the browser entirely: seed the database entry from outside the app and assert the assets load. `de37a0eb` removed the app's test-only seeding and reset commands and replaced them with harness helpers, `reset_app_state` and `seed_databases_config`, which write `databases.toml` into the app's storage sandbox before it launches. Seed an entry whose `s3_key` names the vault secret, add that `s3-credentials` secret through the app's own add-secret UI, then drive the existing `open-database` command and assert the seeded assets appear. This path has been run by hand against MinIO and works end to end.

Prefer the second unless the browser listing itself is what you mean to cover, and say in the test's header comment which behaviour it asserts.

The only difference from the desktop test is the endpoint. The emulator runs on the host and the app runs on the device, so the app must reach it at the host's address on the device's network, not at `localhost`. Use the existing per-platform host-address helper in `apps/smoke-tests/lib/`.

### Step 9: Verify the mobile queue-source behaviour

Browsing a bucket runs `listS3Dirs` as a background task on the embedded engine. Confirm by reading `apps/android-frontend/.../jsengine/EnginePool.java` and `apps/ios-frontend/.../JsEngine/EnginePool.swift` that a source added to `cancelledSources` by `cancelTasks` is cleared when a new task is queued from the WebView.

If it is not, the second browse in step 8 will silently return nothing, because closing the browser shuts its `TaskQueue` down, which cancels the source. Fix it in the engine pool so `addTask` clears the source, keeping the check in `queueChildTask` so children of a batch being cancelled are still dropped. Do not work around it by giving each listing a unique source tag: that hides the fault and it will resurface elsewhere.

### Step 10: Remove any remaining skip machinery

Search both suites for skip guards and environment gates around S3, and remove them. A test that reports success without asserting is worse than no test. Check `apps/smoke-tests/lib/`, `apps/smoke-tests/run.sh` and `apps/desktop/smoke-tests.sh` for helpers that exist only to support skipping.

## Unit Tests

- `packages/storage/src/tests/s3-path.test.ts` for `parseS3ListPath`: bucket with a key, bucket with a trailing slash and no key, bucket alone with no slash, and an empty bucket rejected.
- `packages/storage/src/tests/s3-addressing.test.ts` for `requiresPathStyleAddressing`: IPv4 literal, IPv6 literal, `localhost`, `127.0.0.1`, a port on each, a DNS name, and a real provider endpoint.
- No unit tests for `scripts/s3-emulator.sh` or `scripts/seed-s3-bucket.ts`; they are test infrastructure exercised by the smoke tests themselves.
- No unit tests for the modified React components, per the repository rule. Step 6 is covered by the smoke tests.

## Smoke Tests

- `apps/desktop/smoke-tests/<n>-s3-database/test.sh` (new).
- `apps/smoke-tests/tests/<n>-s3-database/test.sh` (new; the old test 33 was deleted, not rewritten).

Both assert the same two behaviours: a populated bucket lists its seeded directories by name, and a bad credential surfaces an error rather than an empty list.

Both must run with no environment variables set and must not be skippable.

## Verify

- `bun run compile` is clean.
- `bun run test` passes.
- `bun run test:all` passes, including the new desktop S3 test.
- `bun run test:and` passes with every test green, including the new mobile S3 test.
- Every `data-id` the new tests drive is present in a component in `packages/user-interface/src/`. Grep each one: a `data-id` that appears only in a test script is a test asserting against a screen that does not exist.
- Running the desktop S3 test twice in a row passes both times, proving the emulator is cleaned up between runs.
- Two suites started at the same moment both pass, proving the dynamic port works.
- `grep -ri "TEST_S3_BUCKET" apps/ scripts/` returns nothing.
- `grep -rn "SKIP" apps/smoke-tests apps/desktop/smoke-tests` returns no S3-related skip.
- No certificate, CA, TLS proxy or trust anchor is added anywhere in the repository.
- The MinIO cache directory is ignored by git and no binary is committed.

## Notes

- **Plain HTTP is the point.** In an earlier attempt the mobile S3 client forced TLS regardless of the URL scheme, and the response was a certificate authority, a generated certificate, an Android trust anchor and a Bun TLS proxy, all of it in the repository to serve one test. It also surfaced an emulator clock skew that made certificates look expired, and a MinIO file-descriptor exhaustion under its TLS front end. None of that is necessary once the real SDK is in use. If TLS starts creeping back in, the prerequisite in step 1 was not really met.
- **Steps 2 and 3 are product fixes, not test scaffolding.** The S3 browser cannot list a bucket root, and cannot reach any endpoint given as an IP address, for every user on every platform. They are in this plan because it is the work that exposes them. Confirm each is still needed after the SDK conversion before writing it.
- **Do not use a fixed port.** Several suites run at once against a pool of emulators.
- **The mobile app reaches the host by the emulator's host address**, which differs between a NAT emulator, a bridge-attached emulator and a physical device on `adb reverse`. Use the existing helper rather than hardcoding.
- Step 9 is listed as verify-then-fix rather than fix, because the engine-pool behaviour may already be correct depending on what else has landed. Read the code first.
- The seeded prefixes must be directories, not just objects, because the browser lists directories. Two are enough to assert on ordering.
- Deleting the `TEST_S3_BUCKET` guard removes the only reason the mobile test could pass without a server. Expect it to fail the first time it genuinely runs; that failure is information, not a reason to reinstate the guard.
- **Do not configure the emulator for virtual-host addressing.** MinIO can be told to accept `bucket.host` requests by setting `MINIO_DOMAIN`, and that does make an unfixed client work. It is the wrong fix: it papers over step 3, leaves every real user pointing at an IP-address endpoint broken, and makes the test pass for a reason the product does not share. If the emulator seems to need `MINIO_DOMAIN`, step 3 is not working.
- **Read the component before writing an assertion.** The deleted test 33 is the cautionary case: its element ids and its `/s3-browser` route were invented to fit the feature as imagined, and because the test skipped by default nothing ever contradicted them. Any `data-id` a test drives must be greppable in `packages/user-interface/src/`.
