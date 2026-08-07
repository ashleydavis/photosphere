# Audit every test that can pass without asserting anything

## Overview

The three suites (CLI, Electron, mobile) report a pass count. Nobody knows how much of that count is real. At least one test was passing for months while executing none of its body, and it was found by accident rather than by looking.

This plan is a read-and-report audit. It finds every test that can report success without proving anything, classifies what is wrong with each, and produces one document listing them. It fixes nothing: each fix is separate work with its own justification, because bundling a fix into an audit hides how bad the audit was.

## Why this is worth doing (read this before deleting the plan)

**A green suite is only worth what its weakest test asserts.** The value of running these suites is the confidence they give. If some unknown fraction of them assert nothing, that confidence is unearned and there is currently no way to tell which fraction.

**It has already happened, and the cost was real.** `apps/smoke-tests/tests/33-s3-database/test.sh` exits early unless `TEST_S3_BUCKET` is set, which no normal run sets. It reported a pass every time. When finally made to run, it was driving a screen that did not exist, against storage code that could not list the top of a bucket on any platform. Two genuine user-facing bugs sat behind one vacuous test.

**Skips are only one of the ways this happens.** `plan-remove-test-skipping.md` covers explicit skips. This audit covers the quieter failures, which are harder to find and at least as damaging:

- An assertion that matches the empty string, so it holds whatever the app does.
- A `wait_for_value` on a `data-id` that no longer exists, paired with a timeout that does not fail the test.
- A test whose body runs after the app failed to launch, asserting on nothing.
- A command whose failure is swallowed, by a missing `|| exit 1`, a `|| true`, or a pipeline that hides a non-zero status.
- A test that clicks an element the driver cannot actually activate, so the screen never changes and the assertions describe the starting state. This is exactly the radio-button fault in `plan-fix-test-driver.md`, and it means a test can be vacuous without a single suspicious line in it.
- A test asserting only on things that are true before it does anything.

**Why an audit rather than fixing as you go:** the number matters. "Six of ninety tests assert nothing" is a fact that changes how much the suite is trusted and what gets fixed first. Discovering them one at a time while doing other work produces neither the number nor the priority, and each one gets rationalised away in the moment. That is what happened before.

**Cheap to do, and it does not touch product code.** The output is one document.

## Issues

## Steps

This plan changes no source files. Steps 1 to 5 read code and accumulate findings; step 6 writes them up.

### Step 1: Enumerate the tests

List every test in all three suites and record the total per suite:

- `apps/desktop/smoke-tests/*/test.sh`
- `apps/smoke-tests/tests/*/test.sh`
- the CLI suite's test list

Record the count each runner reports for a full run, and check it against the number of directories. A mismatch is itself a finding.

### Step 2: Find early exits and swallowed failures

For each test, check for:

- Any `exit 0` reached before the last assertion.
- Any environment variable that gates the body.
- Commands issued without `|| exit 1` where neighbouring commands have it, which usually means the failure is discarded.
- `|| true`, `set +e`, or a pipeline whose exit status comes from the wrong command.

Record file, line and which assertions become unreachable.

### Step 3: Find assertions that cannot fail

For each assertion in each test, decide whether there is any app state that makes it fail. Look for:

- Patterns that match the empty string, or that match the value the field holds before the test acts.
- `grep` without an anchor where the searched text appears in the log regardless of outcome.
- A wait helper whose timeout path does not fail the test.
- Assertions that only confirm the test's own setup, not the behaviour under test.

Record the specific reason each one cannot fail. "Looks weak" is not a finding; state the input that would make it pass wrongly.

### Step 4: Find assertions against elements that do not exist

Collect every `data-id` referenced by every test. Cross-check each against the `data-id` attributes present in `packages/user-interface/src`. A reference to an attribute that does not exist means the test is driving nothing, and whether that fails the test depends on the helper used.

Record every missing `data-id`, the test that references it, and whether its absence currently fails the test.

### Step 5: Prove the doubtful ones by breaking them

For every test flagged in steps 2 to 4, and for a sample of tests not flagged, run the test with the behaviour under test deliberately broken, and record whether it fails.

This is the only step that produces certainty. A test that still passes with the feature broken is vacuous, whatever it looks like. A test that fails is doing its job, whatever it looks like. Keep the breakage local and revert it immediately after each check; make no lasting change to any source file.

Sampling the unflagged tests matters: it measures how good steps 2 to 4 were at finding things, and the sample result belongs in the report.

### Step 6: Write the report

Create `docs/testing/vacuous-test-audit.md` containing:

- The count per suite: total tests, confirmed vacuous, confirmed sound, not checked.
- A table of every vacuous test: suite, test, file and line, why it cannot fail, and what it was supposed to cover.
- The result of the step 5 sample, stated plainly, including how many unflagged tests turned out to be vacuous.
- A ranked list of what to fix first, ranked by what the test was meant to protect rather than by how easy the fix is.

State the headline number in the first paragraph. If it is bad, say so there rather than further down.

## Unit Tests

None. This plan writes a document and changes no functions.

## Smoke Tests

None added. The existing suites are the subject of the audit, not its target.

Any breakage introduced in step 5 must be reverted immediately, and step 5 is only complete once all three suites are back to the same results they gave before the audit started. Record those results before starting.

## Verify

- `git status` shows exactly one added file, `docs/testing/vacuous-test-audit.md`. Any other modified file means step 5 was not cleaned up.
- `bun run test:all` and `bun run test:and` give the same results as the pre-audit baseline recorded in step 1.
- Every test in every suite appears in the report in exactly one of the four categories.
- Every entry marked vacuous names the specific reason it cannot fail, not a general impression.
- Every entry marked vacuous was confirmed by step 5, not only by reading.

## Notes

- **Fix nothing here.** A fix folded into the audit removes the evidence of how bad it was. Each fix is separate work with its own plan and its own justification.
- **Do not weaken the definition when the number gets embarrassing.** A test that passes with the feature broken is vacuous. That is the whole test.
- The audit should be repeatable. Prefer checks that can be rerun over judgements that live only in this report.
- `plan-remove-test-skipping.md` and `plan-fix-test-driver.md` both remove causes this audit will find. Running them first shrinks the audit; running the audit first tells you how much they were worth. Either order works, but do not run them concurrently with the audit or the baseline in step 1 shifts under it.
