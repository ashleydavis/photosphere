# End-to-End Tests

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

**Do not skip prep.** Every command in a test's Prep section is run, from every code block in it. A skipped prep command makes a test fail for no reason, so when a test fails, first check that every prep command ran.

Manual end-to-end test scripts for Photosphere interfaces.

This directory is "the testing manual". When the human says "the testing manual", they mean these test scripts, the checklist and its notes, run with the commands below.

## Structure

- [cli/](cli/) - Test scripts for the `psi` CLI
- [desktop/](desktop/) - Test scripts for the Photosphere desktop app
- [mobile/](mobile/) - Test scripts for the Photosphere mobile app on Android and iOS
- [CHECKLIST.md](CHECKLIST.md) - Every test, with its result for the upcoming version
- [CHECKLIST-NOTES.md](CHECKLIST-NOTES.md) - Notes from test runs: what failed and why, and anything else seen along the way
- [agent-driving.md](agent-driving.md) - How an agent performs the UI steps itself on Android, iOS and the desktop app

## The testing process

### Test scripts

Each test is a markdown file in three parts:

- **Prep**: setup and cleanup commands. Every test keeps its data in its own `/tmp/psi-…` folder, named in its Prep, so tests never share state.
- **Test**: the steps under test, each with what to expect.
- **Check**: the commands that check the results.

A mobile test starts by wiping the app on the emulator or simulator with `bun run android:reset` or `bun run ios:reset`. `bun run android:50` and `bun run ios:50` (or `:1`, `:0`) start the app with a test database open, and `bun run android:add-fixtures` and `bun run ios:add-fixtures` put photos and videos in the device's photo library. A test that needs S3 gets a fresh bucket on a local MinIO server: see [MinIO for the manual tests](minio.md).

### The checklist

[CHECKLIST.md](CHECKLIST.md) lists every test, grouped by section (CLI, Desktop, Mobile) and group. Each test is marked:

- `- [ ]` untested
- `- [x]` passed
- `- [-]` failed

Only the checklist holds the marks. Notes about a run go in [CHECKLIST-NOTES.md](CHECKLIST-NOTES.md), under the same section, group and test headings as the checklist. A note marked **revist and confirm** is for the human to confirm on the next run of that test; nothing else removes it.

When a test's expectation contradicts its fixture, or names a button or page the app does not have, the test is wrong: the test file is fixed, the fix is recorded in the notes and the test is run again. When the app does something different from what the test expects, the test fails.

### Commands

These Claude Code commands run the process:

- `/test:manual-walkthrough [section or test]` takes you through the untested tests one step at a time. For each step it shows the command and what to expect. You run it, or reply `y` for Claude to run it. A step Claude runs is shown with its output, the result, the expectation and a 🟢 or 🔴 match line. Name a section or test to start there, or to go through tests that have already passed or failed. Desktop steps Claude runs drive a test-hooks build of the app in a visible window.
- `/test:auto-walkthrough <subagents>` runs every untested test without you, using the given number of subagents. Desktop tests run in a hidden window. It marks each test passed or failed, writes notes for failures, removes notes that no longer apply and reports the results at the end.
- `/test:reset-checklist` sets every test back to untested, for a fresh round of testing. It leaves the notes alone.
- `/test:everything` runs the automated test set (`bun run test:everything`), which is separate from these manual tests.
