# Remove the ability to skip tests from every suite

## Overview

Three separate mechanisms let a smoke test report success without running: an environment-variable gate on S3 credentials, an environment-variable gate on the LAN bridge, and a platform guard. All three print a `SKIP` line and then `exit 0`, which the runner counts as a pass.

This plan removes every one of them and removes the machinery that supports them, so a test can only pass by running and asserting.

## Why this is worth doing (read this before deleting the plan)

**A skipped test is counted as a passed test.** Each of these paths ends in `exit 0` with a success log line. The suite summary says everything passed. Nothing in the output distinguishes "asserted and passed" from "did nothing".

**This is not hypothetical, it already hid a broken feature.** `apps/smoke-tests/tests/33-s3-database/test.sh` gates on `TEST_S3_BUCKET` (line 22). That variable is not set in any normal run, so the test has never executed. When it was finally made to run, it turned out to be driving a page that did not exist, against S3 code that could not list the top of a bucket on any platform. The test had been "passing" the entire time.

**The skips are load-bearing in the wrong direction.** `PHOTOSPHERE_NO_LAN_BRIDGE=1` exists so CI can run without a bridge, and it silently drops exactly the two tests that cover host-to-device LAN sharing (`apps/smoke-tests/lib/common.sh` line 534). The result is that the tests most likely to break in CI are the ones CI does not run.

**The cost of keeping them is unbounded.** Every skip is a permanent blind spot that reports as green. There is no alert, no counter, and no summary line that tells you how much of your green is real. The number of skipped tests can grow forever without anyone noticing.

**The counter-argument, and why it does not hold:** skips exist so the suite runs on a machine without credentials or a bridge. That is a real need, and the answer is to provision the infrastructure rather than to skip. `plan-s3-smoke-tests-minio.md` does exactly that for S3: the test starts its own server, so nothing needs configuring and there is nothing to skip. Where infrastructure genuinely cannot be provisioned, the honest outcome is a failing test that says so, not a passing one that lies.

## Issues

- [ ] The release workflow sets `PHOTOSPHERE_NO_LAN_BRIDGE=1` because its emulator is booted by an action that attaches no tap device. Removing the flag makes those tests fail in CI until the workflow builds a bridge first. Decide whether this plan also changes the workflow, or whether that is separate work, before starting step 3.

## Steps

Each step must leave `bun run compile` clean and `bun run test` passing before it is done.

### Step 1: Inventory every skip

Search all three suites for skip paths and record each one with file, line and trigger:

- `git grep -n "SKIP" apps/smoke-tests apps/desktop/smoke-tests apps/cli`
- `git grep -n "exit 0" apps/smoke-tests/tests apps/desktop/smoke-tests` and check each for an early exit before any assertion.
- Any environment variable that changes whether a test body runs.

Known at time of writing, to be confirmed rather than assumed:

- `apps/smoke-tests/tests/33-s3-database/test.sh` line 22, gated on `TEST_S3_BUCKET`.
- `apps/smoke-tests/lib/common.sh` line 534, gated on `PHOTOSPHERE_NO_LAN_BRIDGE`.
- `apps/smoke-tests/lib/android.sh` lines 41 and 73, which relax the readiness check under the same flag.
- `apps/smoke-tests/tests/28-host-emulator-comms/test.sh` line 15, a platform guard that skips on anything that is not Android.

Report the full list before changing anything. If the inventory turns up skips beyond these, they are in scope.

### Step 2: Remove the S3 credential gate

Delete the `TEST_S3_BUCKET` check and its early exit from `apps/smoke-tests/tests/33-s3-database/test.sh`, and remove every use of `TEST_S3_BUCKET` from the test body.

This test cannot pass without a server, so it must be done together with, or after, `plan-s3-smoke-tests-minio.md`, which gives it one. Do not leave a gate in place as a stopgap. If that plan has not run, this step's outcome is a genuinely failing test, which is the correct state and the point of the exercise.

### Step 3: Remove the LAN bridge gate

- Delete the `PHOTOSPHERE_NO_LAN_BRIDGE` branch and its `SKIP` line from `apps/smoke-tests/lib/common.sh`, and the helper it lives in if nothing else calls it.
- Delete the two `PHOTOSPHERE_NO_LAN_BRIDGE` branches in `apps/smoke-tests/lib/android.sh` so the readiness check has one behaviour: the bridge is required.
- Remove the flag from `apps/smoke-tests/run.sh` and from any documentation that describes it, including `apps/android-frontend/CLAUDE.md`.

Resolve the open issue above first: this makes the LAN tests fail in CI until the workflow provides a bridge.

### Step 4: Remove the platform guard

`apps/smoke-tests/tests/28-host-emulator-comms/test.sh` skips when the platform is not Android. A test that is meaningless on a platform should not be dispatched to it at all, rather than dispatched and then skipped.

Change the runner to select tests per platform, so a test that does not apply is never listed as having run. Add a per-test marker file next to the existing `.exclusive` convention (for example `.android-only`) that the runner reads when building its list, and make the run summary report the count of tests dispatched, so a shrinking suite is visible rather than silent.

If the check in that test in fact applies to iOS as well, delete the guard and let it run everywhere. Read it before deciding.

### Step 5: Remove the machinery and make skipping impossible to reintroduce

- Delete any remaining helper whose purpose is skipping.
- Make the runner treat a test that produces no assertion output as a failure, so a future early `exit 0` cannot masquerade as a pass. The mechanism must be simple: if the check is complicated, prefer having each test print a completion marker as its last line and having the runner require it.
- Add a line to `docs/testing/README.md` stating that tests are never skipped, and what to do instead when a test needs infrastructure.

## Unit Tests

This plan changes shell scripts, which carry no unit tests, so it adds none.

`apps/smoke-tests/android-lock.test.sh` already covers the runner's locking and must keep passing; if step 4 changes how the runner builds its test list, extend that script rather than adding a new one.

## Smoke Tests

The suites are themselves the test here. The check is what the suites do after the change:

- Every test in `bun run test:and` runs, with no `SKIP` in the output.
- Every test in `bun run test:all` runs, with no `SKIP` in the output.
- The reported test count matches the number of test directories dispatched for that platform.

## Verify

- `bun run compile` is clean.
- `bun run test` passes.
- `git grep -n "SKIP" apps/ scripts/` returns nothing in test code.
- `git grep -n "TEST_S3_BUCKET\|PHOTOSPHERE_NO_LAN_BRIDGE" .` returns nothing.
- `bun run test:all` and `bun run test:and` both run every test, and the run summary states how many were dispatched.
- Deliberately breaking one test makes the suite fail. Deliberately adding an early `exit 0` to one test also makes the suite fail rather than pass, which is what step 5 exists to guarantee.

## Notes

- **Proper fix, not a workaround.** Do not replace a skip with a test that passes trivially, an assertion weakened until it always holds, or a `|| true`. Those are the same fault wearing different clothes.
- Expect the suite to go red when the gates come off. That is information being recovered, not damage. Each failure is a thing that was already broken and hidden.
- Keep the diff small and mechanical: this plan deletes code, it does not restructure the runner beyond what step 4 needs.
- The platform-selection work in step 4 is the only genuinely new machinery here. If it starts to grow, stop and reconsider: deleting the guard and letting the test run everywhere may be the smaller correct answer.
