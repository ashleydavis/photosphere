# Walk the branch back to green, one commit at a time, then gate commits on tests

## Overview

Every commit on `mobile` after `bb7cc09d` is untested or red. `61ac4cee` moved the mobile config from WebView localStorage to `databases.toml` and broke 8 of 37 Android smoke tests, and it was committed and pushed without `bun run test:and` ever being run. Two later attempts to fix it (`4f21321b`, `d27710a6`) also failed in CI and were dropped from the branch. This plan replays the branch in place from the last known-green commit, one commit at a time, running the full test set at each step, fixing what that commit broke with the smallest possible diff, and stopping for human approval before every amendment. It then closes the hole that let this happen: there is currently no git hook of any kind, and nothing stops an agent committing work it never tested.

## Issues

## What went wrong the first time this plan was run

The first attempt was abandoned partway and its worktree thrown away. It got as far as proving the base and commits 1 to 4 green, diagnosing and fixing all 8 failures at `61ac4cee`, and walking 6 to 8 green. It was abandoned anyway, for reasons that had nothing to do with the diagnosis and everything to do with how the work was run. Read this section before starting; every item below is a rule for the next attempt, not a war story.

**1. Reviews were skipped.** The plan makes green commits proceed unattended and everything else stop. That exemption was stretched into "keep going until something breaks". After the approved amendment of commit 5, the walk continued through three more commits and started on Part B without bringing anything back. When the plan itself was changed mid-run, that change was absorbed as another task and the walk carried on. Unreviewed work piled up until the human had to stop it by force.

*The rule:* **nothing** continues without approval. Step 3 now stops on every substep, green or red, and the plan no longer contains an unattended path. A green run is a short report and then a wait. Everything else stops too: a fix, a plan change, a decision, a surprise, a question, work that was not in the plan. When the human changes the plan mid-run, that is a stop, not an instruction to absorb and continue. When in doubt whether something needs review, it needs review.

**2. Independent test suites were run one after another.** `test:all` was run, then the mobile suite, then the mobile unit tests, at every commit. They contend for nothing: `test:all`'s parts are in-process unit tests, three CLI suites each owning a separate `test/tmp*` directory, and Electron driving its own app; the mobile suites drive the emulators. Serialising them multiplied the wall clock of every commit by roughly the number of suites, nine times over, and the human had to point it out twice.

*The rule:* start everything at once, wait for all of it, report all of it. See "What all tests means" below, which is now written that way.

**3. Polling replaced waiting.** Progress was checked in a tight loop, emitting a stream of near-content-free status messages. At one point the suite was described as running slowly when 33 seconds of real time had passed across the checks. This wasted the human's attention and buried the information that mattered.

*The rule:* block on the condition (`until <condition>; do sleep 30; done`) and say nothing until it fires. One message when a phase completes, not one per glance.

**4. Work pending review was destroyed.** Asked to roll back, the branch was reset hard without first preserving the fixes that were sitting there waiting to be looked at. The fixes survived only inside the discarded commit, so at the moment the human asked to review them, there was nothing in the working copy to review. That is the opposite of the point.

*The rule:* never `git reset --hard` past work that has not been reviewed. Put the reviewable artifact in the working copy first, then move refs. When a rollback target is ambiguous, the diff being reviewed is the thing to protect, whatever else happens.

**5. The diff grew past what failed.** `8-share-database` passed at commit 5 but was changed anyway, because it carried the same latent defect as three tests that did fail. It was flagged rather than hidden, but the plan says the smallest fix and no changes to files the failure does not implicate, and that is what it should have been.

*The rule:* change what failed. A latent problem in a **test** is a note in the report, not an edit.

**6. A known bug was left in the code.** The Android `fsRename` window was fixed and the identical iOS one was left alone, on the grounds that it could not be tested from Linux. That is not a good enough reason. An untestable fix to a known bug is still better than a known bug, and "I found it and left it" is not an acceptable outcome.

*The rule:* fix every bug you find in the product code, on every platform it affects, in the substep where you find it. If you cannot test the fix, say so plainly in the report and mark the relevant suite `NOT RUN`. This is not in tension with the smallest-diff rule above: that rule is about not rewriting **tests** that did not fail. It has never been permission to leave a defect in the app.

**What was worth keeping.** The technical findings held up and should be re-derived rather than assumed: three test-side causes at `61ac4cee` (the `Database opened` log line now lands after `Load assets task completed`, the card-list re-render now lands after the menu is opened, and recents are stored as names that must resolve against the configured-databases list), plus one real app bug that was not in the original prediction: `HostFunctions.fsRename` deleted the destination before renaming, leaving `databases.toml` briefly absent so a concurrent read failed between its `access` and its `stat`. The failing set was 8 of 37, but not the 8 predicted: `8-share-database` passed and `11-edit-encryption-key` failed. iOS has the same `fsRename` defect in `HostBridge.swift` and was deliberately left alone as untestable on Linux.

## Steps

### What "all tests" means

Two sets, by host platform. There is no new aggregate command and no change to existing scripts.

- **Linux (this machine):** `bun run test`, `bun run test:cli`, `bun run test:electron`, `bun run test:and`.
- **macOS:** the same four host commands, plus `bun run test:ios`.

**Start all of them at once, wait for all of them, report all of them.** They are listed individually rather than as `bun run test:all` because `test:all` chains its parts one after another. Running them in sequence makes each commit take the sum of all of them instead of the longest one, and the walk runs this nine times.

Note that `test:all` includes no mobile suite, which is the mechanical reason this breakage was never seen: the command named "all" never touched the code that broke.

**A suite can die on a signal rather than fail a test.** Running everything at once loads the machine hard. In the first attempt a CLI test (`37-sync-edit-field`) was killed by `SIGILL`, exit 132, while the Android suite ran alongside it; it passed in isolation and in every other run. Treat a signal death (exit 132, 137, 139, or a "terminated by signal" line) as suspected contention, not as a regression: re-run that one test on its own before believing it. A real regression fails the same way twice. Say in the report that this happened and what the re-run showed, rather than quietly re-running until it is green.

Each command is reported separately, by name, with its own result. A command that is not run for a platform reason must be reported as `NOT RUN` with that reason, never omitted and never implied to have passed. On Linux the iOS suites are not run; that must appear in every report.

### Part A: the commit walk

The commits to walk, in order. `bb7cc09d` is the base and is not walked (CI run 30253376649, `android-smoke-tests` success).

| # | Commit | Subject | Expectation |
| --- | --- | --- | --- |
| 1 | `5231653e` | Added selecting a single mobile smoke test by number or name | harness only, expected green |
| 2 | `59594b4d` | Removed the fake LAN-share roundtrip test and planned suite parity | harness plus a `test-driver.ts` deletion, expected green |
| 3 | `f41247c6` | Removed the .slow marker so tests dispatch in order | harness only, expected green |
| 4 | `ecdefe2f` | Stopped run:and prompting for a target while the smoke pool runs | `run-android.sh` only, expected green |
| 5 | `61ac4cee` | Loaded test databases onto mobile; moved its config to databases.toml | **the breaking commit**, 8 Android tests fail |
| 6 | `a2647a1b` | New plan | docs only, expected green |
| 7 | `0f7aad10` | New plans | docs only, expected green |
| 8 | `65f27caf` | Removed an unecessary plan | docs only, expected green |

The branch tip has moved on since this table was written: the commit holding this plan file sits on top of `65f27caf` and is docs-only. Read the real list with `git log --oneline bb7cc09d..<captured-branch>` at Step 1 and walk every commit it shows, rather than trusting the count here. The first attempt found 9, not 8.

**Step 1: Record the pre-walk state.**

The walk runs on whatever branch and whatever checkout it is started in. It does not create, name, switch or assume any branch, and it does not assume a worktree or the main clone. `git rebase -i` is unavailable in this environment, so each commit is rewritten with a detached checkout plus `git commit --amend`, and the rest of the branch is replayed onto it with a non-interactive `git rebase --onto`.

Before touching anything, capture and print two things in the walk's first report: the current branch name from `git branch --show-current`, and the current tip SHA. Every later step refers to those captured values, never to a literal branch name. The tip SHA is the recovery point: the pre-walk state comes back with `git reset --hard <tip-sha>`.

**Step 2: Verify the base is green.**

`git checkout bb7cc09d` (detached, the branch unmoved), then start every command for this platform at once, wait for all of them, and report each result separately. **Then STOP and wait for approval before doing anything else.** The base being green is the premise of the whole walk; if it is not green the walk is meaningless.

**Step 3: Walk the commits, one substep each, in order.**

Every substep is self-contained and every substep ends in a STOP. There is no case in which the walk moves from one commit to the next on its own, and no case in which a commit is amended before the human has seen it. A green result is still a stop: the report is short, but it is still made and still waited on.

**What happens if you do not stop.** This is not hypothetical and it is not a warning about some future policy. It is what happened to the first attempt, in this order: the walk continued past its checkpoints, the human interrupted it repeatedly and was ignored in effect because each interruption was absorbed as another task, the human then aborted the entire worktree and deleted the branch, and every piece of work was thrown away. That included the base and four commits proven green for the first time, a correct diagnosis of all four causes at `61ac4cee`, a verified-green fix, a real Android bug found and fixed with a regression test, and a fully drafted and self-tested Part B. None of it survived. The walk restarts from scratch, which is why you are reading this.

The cost of stopping is one message and a wait. The cost of not stopping is everything done so far. Stop.

SHAs below are the originals. From the first amendment onward every later commit has a new SHA, so read the current one from `git log <captured-branch>` rather than using the literal.

**Step 3.1: `5231653e` — Added selecting a single mobile smoke test by number or name.**

Harness only. Expected green. First attempt: green, no changes.

1. `git checkout <sha for 5231653e>` (detached, the branch unmoved).
2. Start every command for this platform at once, wait for all of them, and report each result separately.
3. If any command fails: find the root cause before changing anything. Prove it by reading the app log of each failing test and reproducing at least one failure in isolation. Do not fix on a hypothesis.
4. If any command fails: apply the smallest fix that addresses the cause. No refactors, no cleanups, no unrelated improvements, no changes to files the failure does not implicate. Re-run every command until all are green.
5. **STOP. REPORT. WAIT.** Report the result of every command by name, and, if anything was changed, the failures, the root cause with its evidence, and the diff, left in the working copy where it can be read. This happens whether the commit was green or red: green is a short report, not a reason to skip the stop. Do not amend. Do not move on. Wait for explicit approval to continue. **If you skip this stop, the worktree is aborted and every commit walked so far is thrown away.** That is what happened to the first attempt.
6. On approval only, and only if this commit was changed: `git commit --amend --no-edit`, then `git rebase --onto HEAD <old sha for 5231653e> <captured-branch>` to replay the remaining commits onto the amended one.
7. On approval only: go to Step 3.2.

**Step 3.2: `59594b4d` — Removed the fake LAN-share roundtrip test and planned suite parity.**

Harness plus a `test-driver.ts` deletion. Expected green. First attempt: green, no changes. The Android count drops from 38 to 37 here because this commit deletes a test. That is correct, not a regression.

1. `git checkout <sha for 59594b4d>` (detached, the branch unmoved).
2. Start every command for this platform at once, wait for all of them, and report each result separately.
3. If any command fails: find the root cause before changing anything. Prove it by reading the app log of each failing test and reproducing at least one failure in isolation. Do not fix on a hypothesis.
4. If any command fails: apply the smallest fix that addresses the cause. No refactors, no cleanups, no unrelated improvements, no changes to files the failure does not implicate. Re-run every command until all are green.
5. **STOP. REPORT. WAIT.** Report the result of every command by name, and, if anything was changed, the failures, the root cause with its evidence, and the diff, left in the working copy where it can be read. This happens whether the commit was green or red: green is a short report, not a reason to skip the stop. Do not amend. Do not move on. Wait for explicit approval to continue. **If you skip this stop, the worktree is aborted and every commit walked so far is thrown away.** That is what happened to the first attempt.
6. On approval only, and only if this commit was changed: `git commit --amend --no-edit`, then `git rebase --onto HEAD <old sha for 59594b4d> <captured-branch>` to replay the remaining commits onto the amended one.
7. On approval only: go to Step 3.3.

**Step 3.3: `f41247c6` — Removed the .slow marker so tests dispatch in order.**

Harness only. Expected green. First attempt: green, no changes.

1. `git checkout <sha for f41247c6>` (detached, the branch unmoved).
2. Start every command for this platform at once, wait for all of them, and report each result separately.
3. If any command fails: find the root cause before changing anything. Prove it by reading the app log of each failing test and reproducing at least one failure in isolation. Do not fix on a hypothesis.
4. If any command fails: apply the smallest fix that addresses the cause. No refactors, no cleanups, no unrelated improvements, no changes to files the failure does not implicate. Re-run every command until all are green.
5. **STOP. REPORT. WAIT.** Report the result of every command by name, and, if anything was changed, the failures, the root cause with its evidence, and the diff, left in the working copy where it can be read. This happens whether the commit was green or red: green is a short report, not a reason to skip the stop. Do not amend. Do not move on. Wait for explicit approval to continue. **If you skip this stop, the worktree is aborted and every commit walked so far is thrown away.** That is what happened to the first attempt.
6. On approval only, and only if this commit was changed: `git commit --amend --no-edit`, then `git rebase --onto HEAD <old sha for f41247c6> <captured-branch>` to replay the remaining commits onto the amended one.
7. On approval only: go to Step 3.4.

**Step 3.4: `ecdefe2f` — Stopped run:and prompting for a target while the smoke pool runs.**

`run-android.sh` only. Expected green. First attempt: green, no changes. Commits 1 to 4 had never been proven green before that run; they are now.

1. `git checkout <sha for ecdefe2f>` (detached, the branch unmoved).
2. Start every command for this platform at once, wait for all of them, and report each result separately.
3. If any command fails: find the root cause before changing anything. Prove it by reading the app log of each failing test and reproducing at least one failure in isolation. Do not fix on a hypothesis.
4. If any command fails: apply the smallest fix that addresses the cause. No refactors, no cleanups, no unrelated improvements, no changes to files the failure does not implicate. Re-run every command until all are green.
5. **STOP. REPORT. WAIT.** Report the result of every command by name, and, if anything was changed, the failures, the root cause with its evidence, and the diff, left in the working copy where it can be read. This happens whether the commit was green or red: green is a short report, not a reason to skip the stop. Do not amend. Do not move on. Wait for explicit approval to continue. **If you skip this stop, the worktree is aborted and every commit walked so far is thrown away.** That is what happened to the first attempt.
6. On approval only, and only if this commit was changed: `git commit --amend --no-edit`, then `git rebase --onto HEAD <old sha for ecdefe2f> <captured-branch>` to replay the remaining commits onto the amended one.
7. On approval only: go to Step 3.5.

**Step 3.5: `61ac4cee` — Loaded test databases onto mobile; moved its config to databases.toml.**

**The breaking commit.** Expect roughly 8 Android failures of 37. Do not assume which 8: the first attempt's set was `4`, `11`, `16`, `17`, `21`, `22`, `29`, `36`, which is not the set predicted in the Notes. Derive it from the run. The Notes record the four distinct causes found and the warning that the earlier prediction was wrong in two places.

1. `git checkout <sha for 61ac4cee>` (detached, the branch unmoved).
2. Start every command for this platform at once, wait for all of them, and report each result separately.
3. If any command fails: find the root cause before changing anything. Prove it by reading the app log of each failing test and reproducing at least one failure in isolation. Do not fix on a hypothesis.
4. If any command fails: apply the smallest fix that addresses the cause. No refactors, no cleanups, no unrelated improvements, no changes to files the failure does not implicate. Re-run every command until all are green.
5. **STOP. REPORT. WAIT.** Report the result of every command by name, and, if anything was changed, the failures, the root cause with its evidence, and the diff, left in the working copy where it can be read. This happens whether the commit was green or red: green is a short report, not a reason to skip the stop. Do not amend. Do not move on. Wait for explicit approval to continue. **If you skip this stop, the worktree is aborted and every commit walked so far is thrown away.** That is what happened to the first attempt.
6. On approval only, and only if this commit was changed: `git commit --amend --no-edit`, then `git rebase --onto HEAD <old sha for 61ac4cee> <captured-branch>` to replay the remaining commits onto the amended one.
7. On approval only: go to Step 3.6.

**Step 3.6: `a2647a1b` — New plan.**

Docs only (a plan file plus one `CLAUDE.md` line). Cannot break tests. Expected green. First attempt: green.

1. `git checkout <sha for a2647a1b>` (detached, the branch unmoved).
2. Start every command for this platform at once, wait for all of them, and report each result separately.
3. If any command fails: find the root cause before changing anything. Prove it by reading the app log of each failing test and reproducing at least one failure in isolation. Do not fix on a hypothesis.
4. If any command fails: apply the smallest fix that addresses the cause. No refactors, no cleanups, no unrelated improvements, no changes to files the failure does not implicate. Re-run every command until all are green.
5. **STOP. REPORT. WAIT.** Report the result of every command by name, and, if anything was changed, the failures, the root cause with its evidence, and the diff, left in the working copy where it can be read. This happens whether the commit was green or red: green is a short report, not a reason to skip the stop. Do not amend. Do not move on. Wait for explicit approval to continue. **If you skip this stop, the worktree is aborted and every commit walked so far is thrown away.** That is what happened to the first attempt.
6. On approval only, and only if this commit was changed: `git commit --amend --no-edit`, then `git rebase --onto HEAD <old sha for a2647a1b> <captured-branch>` to replay the remaining commits onto the amended one.
7. On approval only: go to Step 3.7.

**Step 3.7: `0f7aad10` — New plans.**

Docs only. Expected green. First attempt: green.

1. `git checkout <sha for 0f7aad10>` (detached, the branch unmoved).
2. Start every command for this platform at once, wait for all of them, and report each result separately.
3. If any command fails: find the root cause before changing anything. Prove it by reading the app log of each failing test and reproducing at least one failure in isolation. Do not fix on a hypothesis.
4. If any command fails: apply the smallest fix that addresses the cause. No refactors, no cleanups, no unrelated improvements, no changes to files the failure does not implicate. Re-run every command until all are green.
5. **STOP. REPORT. WAIT.** Report the result of every command by name, and, if anything was changed, the failures, the root cause with its evidence, and the diff, left in the working copy where it can be read. This happens whether the commit was green or red: green is a short report, not a reason to skip the stop. Do not amend. Do not move on. Wait for explicit approval to continue. **If you skip this stop, the worktree is aborted and every commit walked so far is thrown away.** That is what happened to the first attempt.
6. On approval only, and only if this commit was changed: `git commit --amend --no-edit`, then `git rebase --onto HEAD <old sha for 0f7aad10> <captured-branch>` to replay the remaining commits onto the amended one.
7. On approval only: go to Step 3.8.

**Step 3.8: `65f27caf` — Removed an unecessary plan.**

Docs only. Expected green. First attempt: green.

1. `git checkout <sha for 65f27caf>` (detached, the branch unmoved).
2. Start every command for this platform at once, wait for all of them, and report each result separately.
3. If any command fails: find the root cause before changing anything. Prove it by reading the app log of each failing test and reproducing at least one failure in isolation. Do not fix on a hypothesis.
4. If any command fails: apply the smallest fix that addresses the cause. No refactors, no cleanups, no unrelated improvements, no changes to files the failure does not implicate. Re-run every command until all are green.
5. **STOP. REPORT. WAIT.** Report the result of every command by name, and, if anything was changed, the failures, the root cause with its evidence, and the diff, left in the working copy where it can be read. This happens whether the commit was green or red: green is a short report, not a reason to skip the stop. Do not amend. Do not move on. Wait for explicit approval to continue. **If you skip this stop, the worktree is aborted and every commit walked so far is thrown away.** That is what happened to the first attempt.
6. On approval only, and only if this commit was changed: `git commit --amend --no-edit`, then `git rebase --onto HEAD <old sha for 65f27caf> <captured-branch>` to replay the remaining commits onto the amended one.
7. On approval only: go to Step 3.9.

**Step 3.9: the commit holding this plan file, and anything above it.**

Docs only. Expected green. There is no fixed SHA: it moves every time this plan is edited, and there may be more than one commit here by the time the walk runs. Step 1's `git log --oneline bb7cc09d..<captured-branch>` defines this substep. Walk every commit it lists that is not covered by Steps 3.1 to 3.8, one at a time, applying the same seven points. The first attempt found exactly one such commit and was aborted before finishing it, so this substep has never been proven green.

1. `git checkout <sha>` (detached, the branch unmoved).
2. Start every command for this platform at once, wait for all of them, and report each result separately.
3. If any command fails: find the root cause before changing anything. Prove it by reading the app log of each failing test and reproducing at least one failure in isolation. Do not fix on a hypothesis.
4. If any command fails: apply the smallest fix that addresses the cause. No refactors, no cleanups, no unrelated improvements, no changes to files the failure does not implicate. Re-run every command until all are green.
5. **STOP. REPORT. WAIT.** Report the result of every command by name, and, if anything was changed, the failures, the root cause with its evidence, and the diff, left in the working copy where it can be read. This happens whether the commit was green or red: green is a short report, not a reason to skip the stop. Do not amend. Do not move on. Wait for explicit approval to continue. **If you skip this stop, the worktree is aborted and every commit walked so far is thrown away.** That is what happened to the first attempt.
6. On approval only, and only if this commit was changed: `git commit --amend --no-edit`, then `git rebase --onto HEAD <old sha> <captured-branch>`.
7. On approval only: go to the next commit in the list, or to Part B when the list is exhausted.

The STOP at point 5 is the point of this plan. Seeing green and continuing without stopping, or making a fix and amending it without stopping, terminates the process and the walk restarts from scratch. That is not a threat, it is what happened: the first attempt was thrown away at Step 3.9 for exactly this.
### Part B: the gate

Each step must leave `bun run compile` clean and `bun run test` passing before it is done.

**Step 4: Add checked-in git hooks.**

`.git/hooks` currently holds only the stock samples and `core.hooksPath` is the default, so nothing runs at any point. Create a checked-in `.githooks/` directory and a `scripts/install-hooks.sh` that runs `git config core.hooksPath .githooks`.

Two hooks, split by cost, because the full set is far too slow to run on every commit:

- `.githooks/pre-commit`: `bun run compile` and `bun run test` only. Fast enough to never be a reason to bypass.
- `.githooks/pre-push`: every command for the host platform, detected with `uname`. This is the real gate, and it is where the mobile suite belongs (about 113 seconds across six emulators, measured, `docs/testing/README.md`).

Both hooks must print, on failure, the exact command to re-run. Neither may auto-fix or auto-stage anything. Both honour `--no-verify`, which git does natively.

Add a changed-paths rule to `.githooks/pre-push`: if the push contains changes under `packages/mobile-frontend/`, `packages/mobile-worker/`, `apps/android-frontend/` or `apps/smoke-tests/`, the mobile suite is mandatory and the hook fails rather than skipping it when no device is attached. Unit tests cannot see embedded-worker task ordering or the on-device config file, which is exactly what `61ac4cee` broke.

**Step 5: Add the agent-side guard.**

The hooks do not stop the failure that actually occurred: an agent running `git commit` in a shell having never run the tests. Add a `PreToolUse` hook to `.claude/settings.json` matching `Bash`, blocking any command containing `git commit` or `git push` unless a marker file, written by a successful run of every command for the platform, exists and is newer than the newest tracked file modification. Fail closed: no marker, no commit.

`.claude/settings.json` currently has no `hooks` key. Adding one is the change.

**This step is blocked until the human chooses.** The Notes list three options for the gate and the choice was never made in the first attempt, so Step 5 was drafted on an assumption. Do not repeat that. On reaching this step: STOP, restate the three options in two lines each, and wait. Do not implement any of them first and offer to revert; that is the same mistake in a different order.

**Step 6: Document it.**

A setup doc already exists: `docs/development.md` has a `## Setup` section and is linked from `README.md`. Do not start a new one. Hooks that are checked in but undocumented are hooks nobody installs, which is worse than none, because the repo then looks gated when it is not.

1. Create `docs/git-hooks.md`, a short reference doc matching the length of `docs/theme-override.md` rather than the long guides. It covers: that `scripts/install-hooks.sh` sets `core.hooksPath` and is per-clone and not automatic; what each hook runs; why the split (the full set is too slow for every commit, the mobile suite alone is about 113 seconds across six emulators); the changed-paths rule and its reason (unit tests cannot see embedded-worker task ordering or the on-device config file, which is exactly what `61ac4cee` broke); how to bypass with `--no-verify` and when that is legitimate (docs-only commit, work-in-progress push to a personal branch, not "the emulator was not running"); how to confirm the hooks are active with `git config core.hooksPath`; and that the hooks are the fast local gate while `.github/workflows/release.yml` is the slow authoritative one.
2. Add the hook install to the `## Setup` section of `docs/development.md`, after the `bun install` block, as a once-per-clone command with a one-line reason and a link to `docs/git-hooks.md`. It belongs in Setup, not Common commands.
3. Add `docs/git-hooks.md` to the `## Guides` list at the bottom of `docs/development.md`, in the same `- [Title](path) - One line description.` form as the existing entries.
4. Fix the Common commands table in `docs/development.md`. The `bun run test:all` row currently reads "Unit tests plus the CLI and Electron smoke tests", which is true but reads as complete, and that incompleteness is the mechanical reason this breakage went unnoticed. Say explicitly that it covers no mobile suite.
5. Add a short cross-link in the `## Running tests` section of `docs/testing/README.md` pointing at `docs/git-hooks.md`. One or two sentences. Do not restate what each hook runs.
6. Add the one-line rule to the Commands section of `CLAUDE.md`: mobile changes require `bun run test:and` before commit, and `bun run test:all` does not cover the mobile suites.

The three statements of the mobile-suite rule (`docs/git-hooks.md`, `docs/testing/README.md`, `CLAUDE.md`) must agree with each other and with what `.githooks/pre-push` actually does. Read the hook and compare rather than assuming.

**Step 7: Commit Part B on top, then hand over.**

After the last commit of the walk is green, commit the hooks and docs as a new commit on top of the captured branch. It is new work, not a fix to any existing commit, so it is not amended into anything.

Then **STOP. REPORT. WAIT.** Report the branch name and tip SHA, `git log --oneline bb7cc09d..<captured-branch>`, the result of every command by name with the iOS suites marked `NOT RUN`, and anything left undone or untested.

Getting this onto `mobile` is the human's job. Do not push, do not merge, do not rebase onto `mobile`, and do not delete the worktree or its branch.

## Unit Tests

- `.githooks/pre-commit` and `.githooks/pre-push` are shell, so they are tested by shell, following the existing pattern of `apps/smoke-tests/runner.test.sh` and `apps/smoke-tests/timeout.test.sh`. Add `scripts/hooks.test.sh` covering: pre-commit refuses a commit when its test command fails; pre-push selects the Android set on Linux and the iOS set on macOS from a stubbed `uname`; the changed-paths rule fires for a diff touching `packages/mobile-frontend/` and does not fire for a docs-only diff. Drive all of it with stubs, running no real suite and no real push.
- Register `scripts/hooks.test.sh` in the `mobile-harness-tests` job of `.github/workflows/release.yml`, alongside the three existing harness tests, so it runs in CI in seconds without a device.
- No new TypeScript functions are added by this plan. Any fix made during Part A that adds or changes a TypeScript function must come with its own unit test, per the repo rule.

## Smoke Tests

- The walk itself is the end-to-end check for Part A: every command green at all 8 commits.
- For Part B, add a case to `scripts/hooks.test.sh` that runs `.githooks/pre-commit` in a throwaway git repo with a deliberately failing stub test command and asserts the commit is refused with a non-zero exit. A gate never observed refusing anything is not a gate.
- Add a further case running `scripts/install-hooks.sh` in a throwaway git repo and asserting `git config core.hooksPath` comes back as `.githooks`. That is the one instruction in the new doc that can silently be wrong.
- The 8 Android smoke tests that fail at `61ac4cee` (`4-import-photos`, `8-share-database`, `16-remove-recent-database`, `17-replicate-database`, `21-import-video`, `22-edit-database-origin`, `29-stale-recent-database`, `36-prefetch-database`) are the acceptance criteria for that commit's fix.

## Verify

- `bun run compile` clean.
- `bun run test`, `bun run test:cli`, `bun run test:electron` and `bun run test:and` all passing at every one of the 8 replayed commits, and at the Part B commit on top.
- `bash scripts/hooks.test.sh` passing.
- `git log --oneline bb7cc09d..<captured-branch>` shows 9 commits: the 8 original subjects, unchanged, plus the Part B commit.
- `git diff <pre-walk-tip-sha> <captured-branch>` limited to the fixes made during the walk plus the Part B files, with no unrelated changes.
- iOS suites reported as `NOT RUN` with the platform reason in every report.
- Every relative link added or changed in the docs resolves to a file that exists, and every command named in `docs/git-hooks.md` exists as a script in the relevant `package.json` or as a file on disk. Check each rather than assuming.

## Notes

- **The force-push is not free, and I have not been asked to do it.** Commits 1 through 5 are already pushed (the remote is at `61ac4cee`); 6 through 8 are local only. Amending anything in 1 through 5 rewrites published history. Step 7 therefore stops short of pushing.
- **Running the walk in a worktree is the better choice, and it changes two things.** The first attempt ran on a new branch in a worktree rather than on `mobile` directly. That is worth repeating: no published history is rewritten, so the force-push problem below does not arise, and the three descendant worktrees are not orphaned. The two consequences are that the result has to be merged back to `mobile` afterwards as a separate, explicitly approved step, and that `git log --oneline bb7cc09d..<captured-branch>` may list a commit more than the table above. Do not delete the worktree while anything in it is waiting to be reviewed.

- **If the walk is run in a worktree, do not run `bun run test:and` from two checkouts at once.** The Android build lock is keyed by repo path, so a worktree gets a different lock than the main clone, and two runs would build and install the same app id onto the same emulators concurrently.
- **Three worktree branches descend from the range being rewritten.** `fix-test-driver` is at `0f7aad10`. `remove-hand-written-s3-client` and `verify-head-17` are both at `153564a3`, whose merge-base with `mobile` is `0f7aad10`. Rewriting the range orphans all three. They need rebasing onto the new history, or the walk needs to happen before further work in those worktrees. This is the largest hidden cost of the plan.
- **Commits 6 to 8 are docs-only** (plans and `CLAUDE.md`), so they cannot break tests and the walk passes through them unattended. They are still walked rather than skipped, because "the suite is green at this commit" is the claim being established.
- **Commits 1 to 4 are expected green but are not proven green.** The CI run for `ecdefe2f` (30311248288) was cancelled, so there is no evidence for any of them. If one is red, the assumption that `61ac4cee` is the sole breaking change is wrong and worth knowing.
- **The shape of the fix for `61ac4cee` is known, and the earlier guess at it was wrong in two places.** The first attempt ran the suite and got 8 failures of 37: `4-import-photos`, `11-edit-encryption-key`, `16-remove-recent-database`, `17-replicate-database`, `21-import-video`, `22-edit-database-origin`, `29-stale-recent-database`, `36-prefetch-database`. Note that `8-share-database` **passed** and `11-edit-encryption-key` **failed**, the reverse of what was predicted here. The verified fix was: drop the `Database opened` wait in tests 4 and 21; wait for `Database opened` plus the following `Databases page loaded` re-render instead of the `database-photo-count` proxy in 17, 22 and 36; seed the configured-database entries alongside the recents in 16 and 29; and remove the destination pre-delete in `HostFunctions.fsRename` for 11. That last one is an app bug, not a test bug, and is the reason the predicted list was wrong. Step 3 must still re-derive and re-verify from the actual run rather than paste any of this in blind, because it was wrong once already.

- **Why removing the `fsRename` pre-delete is correct, and where it stops being correct.** `HostFunctions.fsRename` did `if (destination.exists()) destination.delete();` before `source.renameTo(destination)`. Storage writes are write-to-`.tmp`-then-rename, so that delete left the real path missing for a moment, and a concurrent reader that had already passed `fs.access` then got ENOENT from `fs.stat`. The delete is unnecessary because Android's `File.renameTo` is a POSIX `rename(2)` on internal storage (ext4/f2fs), which replaces an existing destination atomically. Two caveats to record rather than gloss: the `File.renameTo` Javadoc explicitly refuses to guarantee overwrite or atomicity, so this rests on the platform and on the path being internal storage, not on the API contract; and the existing copy+delete fallback opens a `FileOutputStream` on the destination, which truncates, so on that path a concurrent reader can see a partial file instead of a missing one. That is a narrower window, not zero. A proper fix serialises config reads against writes instead of relying on rename semantics, and is out of scope here.

- **iOS has the same defect and must be fixed too.** `HostBridge.swift` does `removeItem` then `moveItem`, opening the identical window in which the destination path does not exist. Fix it in the same substep as the Android one. The Android fix cannot be copied across: Foundation's `moveItem` fails when the destination exists, so simply deleting the `removeItem` breaks it. Use `replaceItemAt(destination, withItemAt: source)` when the destination exists and `moveItem` when it does not; `replaceItemAt` is the atomic replace and needs an existing destination. Not being able to run the iOS suite on Linux is a reason to report the fix as untested, not a reason to leave a known bug in the code. Report it as `NOT RUN` against the iOS suites, exactly as every other iOS result is reported.

- **`8-share-database` shares the defect that breaks 17, 22 and 36 but wins the race often enough to pass.** Leave it alone unless it actually fails. If it passes, say so in the report and note the latent problem there; do not edit it.
- **A latent race is deliberately out of scope.** `handleSeedDatabases` and `handleSeedRecent` in `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx` fire-and-forget with `void`, so the command returns before the config write lands and two back-to-back seeds are an unserialised read-modify-write on one file. It did not bite in the verified-green run, and `docs/plans/new/plan-remove-test-only-scaffolding.md` deletes those handlers entirely, so fixing it here is work thrown away.
- **Three options for the gate, to choose between at review.** (a) Hooks only (steps 4 and 6): checked in, opt-in per clone, bypassable with `--no-verify`, and does nothing about an agent that commits having never run the tests. (b) Hooks plus the agent guard (step 5): closes the actual failure mode, at the cost of a `PreToolUse` hook constraining every commit in every future session, which will occasionally be wrong. (c) CI-side only: require the `release.yml` jobs to pass before merge, which catches things eventually but does not stop a red commit landing on a branch, which is exactly what happened here. The plan writes (a) and (b); (c) alone would not have caught this.
- **The pre-push hook will be slow.** Only the Android suite has a measured time (113s across six emulators). The Electron, CLI, encrypted and LAN-share suites in `test:all` are unmeasured. If the total is long enough that the hook gets routinely bypassed it is worse than useless, and the pre-commit / pre-push split needs revisiting with real numbers.

## Getting this onto `mobile`

Written after the walk finished, from the state it actually left behind. Not run: this is the human's to do, and every command below rewrites history or moves a branch.

**Where things stand.** The walk ran on `green-commit-walk` in a worktree, starting from `mobile` as it was at the time. The two have since diverged at `ecdefe2f`: `mobile` carries seven commits from there, the branch carries ten. They are the same work, rewritten, so this is a replacement rather than a merge and `git merge --ff-only` will refuse it.

Three things make it more than a branch move, and all three are worth checking are still true before starting, because they were true at the moment this was written and nothing keeps them that way:

- **The remote is behind the rewrite.** `origin/mobile` sat at `61ac4cee`, which the walk rewrote into a new commit with the same subject. Publishing therefore means a force-push, and that is a decision rather than a step.
- **`mobile` gained two commits the walk never saw**, `Updated plan` and `New plan.`, made after the branch was taken. A plain replacement destroys them.
- **Three other worktrees descend from the old history**, `fix-test-driver` and both worktrees sitting on `153564a3`. Rewriting orphans all three, and they need rebasing onto the new commits or abandoning.

Also check `git status` in the main clone first. The replacement options below use `git reset --hard`, which takes uncommitted work with it.

**Option A, keep everything.** Replay the two later commits onto the walked branch and move `mobile` there:

```
git rebase --onto green-commit-walk <sha of the commit those two sit on> mobile
```

Both are docs-only so conflicts are unlikely, with one exception: the walk moved this plan file from `docs/plans/new/` to `docs/plans/done/` while `mobile` still has it at the old path, so expect to resolve that one.

**Option B, replace outright**, only if those two commits genuinely do not matter:

```
git checkout mobile
git reset --hard green-commit-walk
```

Option A is the better default. Option B is simpler and throws work away, which is the thing this whole plan exists to stop doing.

**Afterwards**, in either case: rebase or abandon the three descendant worktrees, and decide separately about the force-push. Do not delete the `green-commit-walk` worktree until `mobile` is where you want it and you have run the tests from it, because until then it is the only place the walked history exists.
