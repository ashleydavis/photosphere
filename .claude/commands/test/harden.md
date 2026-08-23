---
description: Prove the test suites are sound alone and in company. Asks how many runs a rung, then runs the parallel-interference check and the flaky-test ladder, and fixes what they turn red, one minimal committed fix at a time in a worktree, until both pass.
---

# Harden the tests

Two scripts, run one after the other, cheapest first. Keep going until both pass.

- `bun run test:parallel` (`scripts/check-parallel-tests.sh`) proves a suite is sound in company: every suite alone, then every combination of two, self-pairs included. Four solo runs then ten pairs, about an hour.
- `bun run find-flakey-tests -- --ladder --target <target>` (`scripts/find-flakey-tests.sh`) proves a suite is sound alone: `<target>` consecutive green runs of `test`, then `test:cli`, then `test:electron`, then `test:and`. Four times `<target>` runs, hours rather than minutes. The human chooses `<target>`, see below.

The parallel check is the cheaper of the two, so it goes first.

## First, ask how many runs a rung

Before anything else, ask the human how many consecutive green runs of each suite the ladder should require, and wait for the answer. It decides how long the whole job takes and how much a green result is worth, so it is never assumed.

- 10 is the usual answer. The ladder took about three and a half hours at 10 and about four and a half at 20 on this machine, though a failure stops it far sooner than that.
- Below about 10 the result says very little: a mode that fails one run in fifty passes a short streak most of the time.
- The parallel check has no equivalent number. It runs each combination exactly once, whatever is chosen here.

Whatever the answer is, use it everywhere `<target>` appears below.

## Then print the goal

Print this for the human to paste into `/goal`, with `<target>` filled in, so there is something outside the conversation holding the work to finishing rather than to reporting progress:

```
Get scripts/check-parallel-tests.sh and scripts/find-flakey-tests.sh (ladder, --target <target>) both fully green on one tree. Work only in a git worktree, never the main checkout. On each failure make the smallest, most targeted fix for that one problem, comment it with what it fixes and why, commit it on its own with the hook passing (never --no-verify), then re-run whichever script failed. If the same failure returns, remove that commit rather than reverting it and try again. Do not stop, do not declare partial success, and do not widen the scope until a single run of each script passes end to end.
```

Print it and carry straight on. Do not wait for the human to set it.

## The loop

1. Run `bun run test:parallel`.
2. Run `bun run find-flakey-tests -- --ladder --target <target>`.
3. Both passed: write the summary (see "Finishing") and stop.

On a failure of either: fix it as described in "Fixing a failure", then go back to the step that failed, not to the top. A fix that landed while chasing step 2 does not send you back to step 1.

Do not stop part way and report progress instead of a result. A failure is work to do, not an outcome to hand back. The only reasons to stop short are the ones under "When to stop and ask".

## Before each script

Check the emulator pool at the moment you need the answer, never from a reading taken earlier:

```
bun run emu:and:pool:status -- --quiet
```

Exit 0 means at least one pool emulator is up and on the LAN bridge, exit 1 means none is.

- Pool down before `test:parallel`: say so, and say that `test:and` will be dropped from the set, which leaves 5 of the 15 combinations unchecked. Start it anyway. The run prints the same thing itself.
- Pool down before `find-flakey-tests`: say so, and say the climb will reach `test:and` in roughly two hours and needs the pool by then. Start it anyway, because the first three rungs touch no device.

Never bring the pool up, take it down or restart it. That is the human's.

## Running a script

Both take hours. Start each one detached, in the background, with its output going to a log you can read:

```
setsid bash -c 'mise exec -- bun run test:parallel 2>&1 | tee /tmp/claude-.../scratchpad/parallel-NN.log' </dev/null &
```

`setsid` matters: started as an ordinary background task, a run is killed whenever background tasks are cleared, and it then looks exactly like a failure when nothing failed. Four climbs died that way during the work that produced these scripts.

Read the exit status before reading anything else.

`bun run test:parallel`:

- 0: clean. Move on.
- 1: interference. Read `tmp/parallel-check/<timestamp>/report.txt` and the failing side's log. This is a failure to fix.
- 2: bad usage. Your invocation is wrong. Fix it and rerun.
- 3: too many Bun crashes. Not a test failure and must never be fixed as one. Report it and run the script again.
- 4: the emulator pool degraded mid-run. See "A sick pool". Not a failure to fix.
- 5: no interference, but a script failed on its own, so its combinations prove nothing. The unstable script is the failure: loop it with `bun run find-flakey-tests -- --script <name>` to reproduce, fix it, then run `test:parallel` again.

`bun run find-flakey-tests`:

- 0: every rung green. Move on.
- 1: a run failed. Read `tmp/find-flakey-tests/<timestamp>/report.txt` and the failing run's own log in the rung subdirectory. This is a failure to fix.
- 2: bad usage.
- 3: too many Bun crashes. Report and restart the rung, using `--ladder "<remaining rungs>" --target <target> --resume <greens>` exactly as the script prints.
- 4: the pool stopped being healthy and did not come back. See "A sick pool".

On macOS the ladder is `-- --ladder "test test:cli test:electron test:and test:ios" --target <target>`.

## Fixing a failure

**The first failure creates the worktree.** Everything from then on happens there. The main checkout is not to be changed and its branch is not to be moved.

```
git branch --show-current
git worktree add -b harden-tests .claude/worktrees/harden-tests <current-branch>
```

then `EnterWorktree` with the `path` parameter. Never `EnterWorktree` with `name`.

Then, for the one failure:

1. **Read the report before touching any code.** Name the one test that failed and the earliest error line in it, never a downstream "not ready" or timeout that follows from it.
2. **Check `docs/flaky-tests-registry.md`.** Strip ports, PIDs, timestamps, paths, ids, durations and hashes out of that error line and compare it against the patterns there. A match on an unticked entry gives you the recorded root cause to start from. A match on a ticked entry means that fix is disproven: untick it and append the recurrence, per the registry's own rules.
3. **Establish the cause from evidence.** Read the test and the code it drives. Reproduce it narrowly where the logs are not enough: `bun run find-flakey-tests -- --script <suite> --test <filter>` loops one test in seconds. If the cause cannot be established, say so rather than changing code on a guess. Guessing is banned.
4. **Make the smallest change that removes that cause, and nothing else.** No tidying, no renames, no reformatting, no second thing noticed on the way. Widening a timeout is a fix only when the evidence says the wait was genuinely too short for the work; when the evidence says the test raced something, wait for the thing rather than for longer. Contention on a machine-wide name (a fixed port, path, lock or device) is fixed by allocating per run: a free port, or `scripts/lib/allocate-test-temp-dir.sh` for a directory.
5. **Comment the change** with what it fixes and why it is needed, in the code, not only in the commit message.
6. **Prove it goes red without the fix.** Break it back and watch the looped test fail, then restore it and watch it pass. A fix only ever seen passing has not been shown to fix anything. Where the failure is too rare to reproduce on demand, say so plainly in the commit message and in the registry entry instead of claiming a proof you did not get.
7. **Meet the repo's requirements.** `bun run compile` passes. Any new or changed TypeScript function gets a unit test under that package's `src/test`, watched failing first. Changed shell gets no test: `*.test.sh` is banned here.
8. **Record the mode in `docs/flaky-tests-registry.md`**, following the format already in that file.
9. **Commit it on its own**: the fix, its test, and the registry entry, nothing else. Check `git status` and `git diff HEAD` first, because the human stages work as they review it. Never `--no-verify` or `-n`, and never any other way of skipping the hook. A hook refusal is reported to the human and stops the loop.

One fix per commit, one problem per fix.

**If the same failure comes back**, the fix did not work. Remove the commit rather than adding a revert on top, so the history does not fill up with pairs of commits that cancel out. In the worktree, with that fix as the tip commit and nothing else on top of it:

```
git reset --hard HEAD~1
```

This is the one destructive git command this skill authorises, and only in the worktree, and only on a commit this skill made. Then diagnose again from scratch: the first explanation was wrong.

**Every commit must fix a failure one of the scripts actually produced.** Remove any that does not, the same way, before finishing. A change that did not fix an observed failure is not a fix, however reasonable it looks, and shipping it makes things worse rather than better: it is untested behaviour that changes what the app or the harness does, and when it breaks something later there is nothing tying it to a symptom anyone saw. The bar is a failure you watched happen, a cause you established from its evidence, and a change you saw go red without it and green with it.

Judge each commit against that bar and remove the ones that fail it:

- **A fix for a mode you diagnosed but never watched break a run** goes. Finding a real defect while reading the code is not the same as that defect having failed anything, and this skill is for what the scripts turn red. Record it in the registry so the knowledge survives, and leave the code alone.
- **A fix you could not prove**, where no red run was produced and no red/green pair exists, goes, unless the failure it addresses is one the scripts produced and the cause is established from that run's evidence. A number you picked rather than measured is not a fix.
- **Diagnostics stay only when they earned it**: a logging change that named the cause of a failure the scripts produced has paid for itself and should be kept, because the next occurrence is then readable. One added on speculation has not, and goes.
- **A fix that caused a failure of its own** goes immediately, whatever else it was for. That is the rule above, and it is not negotiable because the change was well intentioned.

Say in the summary which commits were removed under this and why, so the reasoning is visible rather than silently dropped.

## A sick pool

Exit 4 from either script, or a `find-flakey-tests` pause, means an emulator went bad. That is not a flaky test and must not be fixed as one.

Ask whether the pool monitor is running, at the moment you need the answer:

```
flock -n /tmp/photosphere-emulator-pool-monitor.lock true
```

Exit 1 means it is running: say which emulator broke, say the monitor will deal with it, and leave it alone. Exit 0 means it is not, and you may run `bun run --filter=android-frontend emu:pool:repair` (add `-- --index N` for one) or the read-only `bun run --filter=android-frontend emu:pool:diagnose`.

For what went wrong earlier, read `/tmp/photosphere-emulator-pool-monitor.log` and `/tmp/photosphere-emulator-pool-monitor-repairs.log` before asking the human anything.

Never run `emu:and:pool:up`, `emu:and:pool:down`, `emu:and:pool:restart`, `emu:and:up`, `emu:and:down`, `emu:and:restart`, never touch a tap or the bridge, and never run sudo.

Once the pool is back, run the script that stopped again.

## When to stop and ask

Only these:

- The commit hook refuses a commit. Report its output and stop.
- The cause of a failure cannot be established from evidence. Say what you looked at and what you could not determine.
- The fix would need something this repository bans: a workaround for a third-party SDK, a fake, a stub, a skipped test, a test-only hook in app code.
- The same failure survives three fixes. Report the three attempts and what each disproved.

Anything else is work to carry on with.

## Finishing

Both scripts green in one pass each, and every remaining commit tied to a failure one of them produced. Then add an entry to `docs/testing/flakey-log.md`, dated today, following the entries already there: the ladder target, the result of each script with its session directory, what failed and what was done about it, and any suite left out of the run. Keep it to a few lines, because the detail of a failure mode belongs in `docs/flaky-tests-registry.md` and the entry points at it. A session that found nothing still gets an entry.

Then write:

- Each fix: which test failed, what the cause was, what the change did, and why it was the smallest change that removes that one cause.
- The evidence that proved each fix, or plainly that a red run could not be produced.
- Any commit removed for not fixing an observed failure, and why. Removing one is a normal outcome of this skill, not an admission of having wasted the time: the knowledge goes into the registry and the code stays as it was.
- Which fixes are proven and which are not, kept apart rather than listed together. A change whose red/green pair you watched and a change you reasoned your way to are not the same claim, and running them together in one list overstates the weaker ones.
- Any Bun crash, sick pool or dropped suite either run reported, and what it leaves unchecked. A `test:parallel` run without `test:and` checked 10 of 15 combinations, and a run without `test:ios` on Linux always does.
- The session directories: `tmp/parallel-check/<timestamp>` and `tmp/find-flakey-tests/<timestamp>`.
- **The worktree path and branch the work is on**, so the human can go and look at it themselves.

Say plainly what these runs do not show: one clean run per combination is not a rate, and a streak of `<target>` will pass most of the time against a mode that fails less often than one run in `<target>`. Say the number that was chosen, so the claim is read against it. Green here means cleaner than before, not clean.

Do not offer to merge, push, or otherwise move the work anywhere.
