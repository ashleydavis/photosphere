---
description: Run every test in the manual e2e testing checklist without the human, using the given number of subagents, marking each test passed or failed and keeping the notes current.
---

# Run the manual testing checklist autonomously

Run every untested test (marked `- [ ]`) linked from `docs/testing/e2e/CHECKLIST.md` yourself, from start to finish, and mark each one passed or failed. Skip tests already marked `- [x]` (passed) or `- [-]` (failed). The human is not following along and gives no input during the run.

`$ARGUMENTS` is the number of subagents to use. Use exactly that many, and never more. When it is empty, ask the human how many subagents to use before doing anything else, and wait for the answer.

## Before you start

- Read `docs/testing/e2e/CHECKLIST.md` and `docs/testing/e2e/CHECKLIST-NOTES.md`.
- Build the desktop app once, before any subagent starts: `bun run --filter=ziggy bundle:ui`, then `zig build photosphere-linux -p tmp/desktop-hooks/test`.
- Run `bun run emu:and:pool:status -- --quiet` to decide whether the Android tests can run, at the moment you start them.
- Split the tests into as many groups as there are subagents, keeping each `###` group whole, and give each subagent one group list. Each subagent runs its tests one after another; the groups run in parallel.

## Running a test

- Run every step in the order the test file writes it: Prep, Test and Check. Do not skip, reorder or merge steps.
- **Do not skip prep.** Run every command in every code block of the Prep section. A skipped prep command makes a test fail for no reason.
- Every test keeps its data in its own `/tmp/psi-…` folder, named in its Prep, so tests in different subagents never share state. Do not use any other folder.
- Desktop steps: start a remote control server with `bun run ziggy-remote-control-server --app-port 0 --script-port 0` (it prints the two ports it listens on), then start the build hidden under `xvfb-run` with `--remote-control 127.0.0.1:<app port>`, the test's export block and the variables `photosphere_platform_start` in `apps/photosphere-smoke-tests/lib/linux.sh` sets, and drive it through the server's script port the way `apps/photosphere-smoke-tests/lib/common.sh` does (`click`, `type`, `navigate`, `pick-answer`, `get-value`, `long-press`, `long-press-click`, `screenshot`, `quit`). Elements are found only by `data-id`, in `packages/user-interface/src`. Use bash for the control connection, since zsh has no `/dev/tcp`. Take a screenshot and look at it for every step whose expectation is about what the window shows.
- CLI steps: run them from the repo root with the test's export block, through `mise exec --`. `psi` is the Zig CLI the test's Prep builds into `zig-out/bin`.
- Android steps run only when the pool check says the pool is up, driven the way `apps/photosphere-smoke-tests` drives Android. iOS steps run only on macOS.
- Record the pid of every app you start, quit it with the control connection's `quit` as soon as its test is done, and check it has exited. Never kill by name or command line.

## Deciding the result

- A test passes when every step's result matches what the test file expects. Compare each step on its own.
- When an expectation contradicts the fixture (the files it names are not the ones the fixture holds) or names a button, field or page the app does not have under any name, the test is wrong: fix the test file, keeping what it checks, record the fix in the notes, and run the test again from Prep.
- Before calling a test failed, check that every prep command ran. If one did not, run the test again from Prep.
- When the app does something different from what the test expects, the test fails. Never change a test's expectation to match what the app did.
- Leave a test unmarked, and say why at the end, only when it cannot run on this machine: another platform's installer, Android with the pool down, iOS off macOS, or a test that adds or removes secrets in the real OS keychain.

## Checklist and notes

- Subagents never edit `CHECKLIST.md` or `CHECKLIST-NOTES.md`. Each one reports back, per test: passed or failed, and for a failure, the step that failed with what was expected and what happened, in a sentence or two, plus any test file it fixed and why.
- You alone write both files, after every subagent has reported.
- Tick a passed test (`- [x]`) and mark a failed one `- [-]`.
- For a failed test, replace its old failure notes with what happened in this run. For a passed test, delete its failure notes.
- Never touch a note marked **revist and confirm**: those are the human's to confirm.
- Delete a `### General` note only when this run showed the problem it describes is gone.
- Notes use the same `##` section, `###` group and `####` test name headings as the checklist.
- A note says what happened to the app or the test, never who did or decided something: no mention of "the human".

## At the end

Report, per section, how many tests passed, how many failed and how many were not run, then name each failed test with its failing step in one line, and each test not run with why.
