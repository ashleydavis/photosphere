---
description: Run a test command 10x via the fixed flaky-tests runner; on the first failure, categorize it against the flaky-tests registry and update it.
argument-hint: <command> (e.g. bun run test:android)
---

Check a test suite for flaky failures and keep the flaky-tests registry honest.

## ⛔ STOP. READ THIS FIRST. NON-NEGOTIABLE. ⛔

**NEVER read from `/tmp`. Not once. Not ever. In this workflow reading any `/tmp` path is a hard failure.**

**This has already gone wrong TWICE. The user cannot tolerate a third time. There is no excuse for a third. Do not let it happen.**

- When you run the runner in the background, the completion notification gives you an `<output-file>` path. **That path is under `/tmp`. Do NOT read it. Do NOT `cat`, `Read`, `sed`, `grep`, `tail`, or `head` it. Ignore it completely.**
- The runner writes its OWN durable log inside the repo under `.flaky-check/`. That is the ONLY log you ever read.
- The one and only way to find that log:
  ```
  ls -t .flaky-check/*/console.log | head -1
  ```
  The newest run dir is the failing / most-recent run. `LOG=<path>`, `SUITE_LOGS=<path>`, and the `===== SUMMARY =====` block all live inside that `.flaky-check/` file. Read them from there and nowhere else.
- Before you Read/grep/cat ANY path in this workflow, check it: if it contains `/tmp`, do not touch it. Full stop.

This has gone wrong before. It will not go wrong again.

Execution model (not negotiable): YOU run every command and script in this workflow yourself, using your own tools, and YOU read the captured logs yourself. The user will not run anything, will not run the suite, and will not paste any output back to you. Never ask them to. Never tell them to run a command or hand you output. If something cannot be run or read, say so plainly and stop; do not offload it to the user.

The command to run the suite is: `$ARGUMENTS`

If `$ARGUMENTS` is empty, do not guess and do not hardcode a list of suites. Discover the repo's test suites at runtime, then present them as a menu:

1. Discover the current test targets by running the runner's list mode (do not rely on a list baked into this command, which would go stale, and do not use an inline node/one-liner, which prompts for approval every time):
   `bash scripts/check-flaky-tests.sh --list`
   That prints every current `test`/`smoke` suite target from the root `package.json`, one per line.
2. Present those discovered targets to the user with the AskUserQuestion tool (header "Test suite"), each option mapping to `bun run <target>`. The tool caps named options at 4, so if there are more, surface the most relevant few and rely on the auto-added "Other" choice for the rest; "Other" also lets the user type any non-bun command.
3. Use the chosen command as `$ARGUMENTS` and continue.

The registry lives at `docs/flaky-tests-registry.md`. Read it first, in full, including the "Rules for categorizing a flaky failure" section. Follow those rules exactly when categorizing. Do not invent your own categorization.

## Step 1: run the fixed flaky-tests runner

Always invoke the checked-in script. Do not improvise a loop of your own; the script is the fixed, identical loop every time. It runs the suite up to 10 times and bombs out at the first failing run:

```
bash scripts/check-flaky-tests.sh $ARGUMENTS
```

The runner executes the command through a shell (`mise exec -- bash -c "$*"`), so it does not matter whether you pass it as separate words (`bun run test:android`) or as one quoted string (`"bun run test:android"`); both run identically. Do not hand-split the command to work around exec errors.

The script captures all output to a durable log under the repo's gitignored `.flaky-check/` dir (never the system temp dir) and prints its path on the last stdout line as `LOG=<path>`. It exits 0 if all 10 runs passed, 1 if a run failed. Each full run can take several minutes, so all 10 can take a while, so run it in the background (or with an extended timeout) rather than a short foreground call.

NEVER read the background task's `<output-file>` from the completion notification: that path is always under `/tmp` and reading it is forbidden. Do not read `/tmp` at all. To get the runner's log, locate it directly in the repo with `ls -t .flaky-check/*/console.log | head -1` (the newest run dir is the failing/most-recent run). The `LOG=<path>` and `SUITE_LOGS=<path>` lines and the `===== SUMMARY =====` block all live inside that `.flaky-check/` file; read them from there, never from the harness's `/tmp` capture.

Never write any output to `/tmp` (or any system temp dir, or the session scratchpad, which also lives under `/tmp`). This is not allowed. Do not append your own `| tee ...`, `> file`, or any other redirection to the runner command: the runner already writes a complete, durable log to `.flaky-check/`, and when you run it in the background the harness already captures its stdout. Run the runner command exactly as written above with nothing added, and read the log the runner itself printed as `LOG=<path>` (a `.flaky-check/...` path). If you need the `===== SUMMARY =====` block or any other output, read it from that `LOG` file, not from a copy of your own.

## Step 2: if the script exited 0 (all 10 runs passed)

Report that the suite ran 10 times clean and no flaky failure was seen. Do not change the registry. Stop.

## Step 3: if the script exited 1, find and categorize the error

When a run fails, go straight ahead and do the analysis, categorization, and registry update (Steps 3 and 4) yourself, autonomously, in one pass. Do not stop, wait, or ask the user any questions first, and do not ask permission to investigate or to add/update a registry entry. Just do it and report the result. You never remove or rework a fix yourself; in Case A you only update the registry and report the disproven fix, leaving the removal to the user.

1. Find the error. Read the `LOG=<path>` console log the script printed. Identify the earliest root error line of the failing run, not a downstream cascade (rule 2). If the script also printed `SUITE_LOGS=<path>`, read the snapshotted suite-side logs there (for the mobile smoke suite these are the per-test app.log/bridge.log) for the real cause.
2. Normalize the error into a signature by stripping volatile tokens (ports, PIDs, timestamps, paths, ids, durations, attempt counts, hashes) per rule 3.
3. Match the signature against every entry's `Pattern` (and any listed cascade pattern) in the registry.

## Step 4: act on the categorization

### Case A: it matches a CHECKED entry (Fixed box ticked)

The fix that was believed to work did not. Per rule 7:

1. Untick that entry's Fixed box and append today's date under Recurrences with a one-line note.
2. Read the entry's `Fix commit`. That is the commit that must be removed so a fresh fix can be tried. Then clear the `Fix commit` field back to "none yet".
3. Do not remove or rework the fix yourself, and do not try to re-fix the mode now. Just report to the user, plainly: which mode recurred, which recorded Fix commit is disproven, and that it needs to be removed and reworked. Leave that removal entirely to the user.

### Case B: it matches an UNCHECKED entry (Fixed box empty)

A known, not-yet-fixed mode recurred. Append today's date under that entry's Recurrences with a one-line note. Report the matched id. Do not tick anything.

### Case C: it matches no entry

A new flaky mode. Per rule 1, first confirm it is actually flaky (the suite passed at least once in this run before failing); if it failed on run 1 and looks deterministic, say so and do not add it. Otherwise add a new entry to the registry with:

- a new descriptive id in the same style as existing ids,
- an unticked `- [ ] Fixed and verified (10x clean)` box,
- `Suite`: the test suite and command it was seen in,
- `Pattern`: the normalized invariant regex,
- `Fix commit`: none yet,
- `First seen`: today plus which run and test failed,
- `Recurrences`: none,
- `Root cause`: your best investigation of why (read the logs; say "unknown, needs investigation" only if you truly cannot tell),
- `Evidence`: the exact failing lines.

Report the new entry.

## Step 5: report

In all cases, end with a summary that includes:

- The per-run timing and result table the script printed in its `===== SUMMARY =====` block: each run's number, PASS/FAIL, and duration, plus the overall result and total time. Reproduce it for the user.
- The categorization result (clean / matched id / regression of checked id / new id).
- The log path (`LOG`), and `SUITE_LOGS` if present.
- The single next action, if any.

Notes:
- Never tick a Fixed box in this command. Ticking only happens after a real fix lands and a later clean 10x run, done deliberately, not here.
- Never remove or rework a fix yourself. In Case A you only update the registry and report the disproven fix; the user handles removing it.
