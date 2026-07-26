---
description: "Review a step's git worktree: summarise the work, strip everything unrelated to its core fix, then verify what remains."
argument-hint: "<worktree-name-or-path> (e.g. step-10-theme-persist)"
---

# Review a step worktree and reduce it to its core fix

Review the work left in a git worktree by an implementation agent, strip out everything that is not required to solve that worktree's one problem, and verify what remains.

The worktree to review is: `$ARGUMENTS`

This command runs unattended. Never ask a question and never wait for a reply: no target menu, no approval gates, no "let the user decide". Make every call yourself and carry on to the end.

**Run every command yourself with the Bash tool. Never hand a command to the user to run, never print a command and wait for them to paste output, never end your turn waiting on the user.** This overrides the usual convention that the user runs commands in their own terminal: for this command you execute the compile, the unit tests, and the Android smoke suite yourself, read their output yourself, and act on it. Any code block below is a command for you to run, not an instruction for the user. The only thing you ever leave to the user is `git worktree remove` (banned here) and committing.

If `$ARGUMENTS` is empty there is no target to review, so you cannot proceed. Print the available worktrees and stop. This is a precondition failure to report, not a menu to wait on: show the list, say a worktree name or path is required and that the user can re-run with either the number or the name, and end your turn. Do not wait for a reply, do not pick one yourself.

- List the directories under `<repo-root>/.claude/worktrees/`, sorted by step number (so `step-6ab` comes before `step-10`, not after).
- Print a **numbered markdown list, one worktree per line**. Never put more than one worktree on a line. A comma-separated run-on of two dozen names is unreadable and is not an acceptable answer.

Build the list from the directory listing alone: do not read any plan, checklist, or other doc. The names are self-describing, and hunting for a description turns this into a fishing expedition through files that may not exist. No preamble, no commentary on the list.

## Hard rules

- **Never write outside the selected worktree. Not once.** The worktree is `<repo-root>/.claude/worktrees/<name>`, and it is the only place you may create, edit, delete, or move a file. The main repo is off limits: any change made there will be summarily reverted. Other worktrees are off limits. The home directory is off limits. Reading outside the worktree is fine (for example a known-good build artifact in the main repo). Writing outside it is never fine, even to "fix" something obviously broken. Report it instead.
- **Resolve the worktree to an absolute path first, and use it everywhere.** Before running anything, work out `<abs-worktree>` and use it in every single command. A bare `cd <relative>` resolves against the main repo, not the worktree, and will silently operate on the wrong tree. This has already caused a build to run in the main repo by mistake.
- **Only read-only git is allowed.** `status`, `diff`, `log`, `rev-parse`, `hash-object`, `show` and the like are fine and necessary. Every git command that changes anything is banned: no `add`, `commit`, `checkout`, `restore`, `reset`, `stash`, `clean`, `branch`, `merge`, `rebase`, `push`. Undo changes by editing files with Edit/Write, or by copying a known-good file with `cp`.
- **This command never commits.** Do not commit, do not stage, do not offer to, and do not end the review by suggesting it. The user decides when to commit and will say so explicitly. An instruction to commit in an earlier message does not carry over.
- **The changes may already be staged.** Do not unstage them. `git diff` alone will then show nothing; use `git diff HEAD` to see the working tree against the last commit, and `git status --porcelain` to spot untracked files.
- **Untracked files matter.** New smoke tests and new source files are usually untracked and invisible to a plain diff. Always start from `git status --porcelain`.

## Step 1: Establish what this worktree is supposed to do

- The diff is the authority on what this worktree does. Start there, not in a doc.
- Optionally, if a plan or checklist in `docs/plans/` happens to name this worktree, skim it for the intended scope. Treat it as the author's claim, not as fact, and do not go hunting if nothing turns up. Never let a doc override what the code plainly does.
- State, in one sentence, the single problem this worktree exists to solve. Everything downstream is judged against that sentence.

## Step 2: Summarise the work (the most important step)

This summary is the whole point of the command. The user's decision is whether to keep this worktree or delete it, and they make that decision from what you write here. Get this right and the rest is mechanical.

Gather, in this order:

- `git -C <worktree> status --porcelain` for the file list, including untracked files.
- `git -C <worktree> diff HEAD --stat` for the shape of the change.
- Read `evidence/summary.md` if present, but treat it as the agent's own claim, not as fact. Verify every claim against the diff.
- Then read the source diff, **always excluding the generated and throwaway files**:
  ```
  git -C <worktree> diff HEAD -- . ':(exclude)*worker.bundle.js' ':(exclude)evidence/*'
  ```

**Never read a `worker.bundle.js` diff.** It is generated, it is hundreds of lines of vendored `node_modules` churn per file, and there are three of them. Reading them has already exhausted an entire run's budget before it reached the summary. The `--stat` line tells you all you need: that the bundle changed. Same for `evidence/`, where the logs run to thousands of lines. Read `evidence/summary.md` and nothing else in there.

If the remaining source diff is still large, read it a few files at a time by pathspec rather than dumping it in one go.

Then answer exactly three questions:

1. **What does the change do?** The actual behaviour change, in plain English. Not a file list.
2. **Why is it useful?** What goes wrong for a real user without it. Concrete symptom, not an abstraction: what they click, what they see, what happens anyway.
3. **Why should the user not just delete this worktree?** The honest case for keeping it. If the case is weak, say the case is weak. A worktree that only rearranges code, duplicates existing coverage, or fixes something no user can hit is a candidate for deletion, and saying so is more useful than defending it.

Also flag anything the fix leaves incomplete. A change that propagates an error nobody catches, for example, is not finished. Say so plainly rather than reporting it as done.

**Apply the `/tmi` skill to this summary before showing it.** A short heading that states the conclusion, then bullet points, minimum words, most important thing first. No preamble, no file-by-file walkthrough, no restating the diff. The user should be able to decide keep-or-delete from the first three lines.

Then **keep going straight into step 3**. Do not stop, do not ask permission, do not end your turn on a question. The summary is something you show the user on the way past, not a checkpoint you wait at. The user asked for a review, and a review that prints an assessment and then stops has done half the job.

The one exception: if your own verdict is that the worktree should be **deleted outright**, say so, say that you cannot remove it (that needs `git worktree remove`, which is banned here), give the user the command, and stop. Stripping files is wasted work if the whole thing is going away.

## Step 3: Separate the core fix from everything else

Classify every changed file as either required for the core fix or not. Common categories of unrelated change, all of which have shown up before:

- **Shared baseline fixes** propagated across many worktrees (a test-driver tweak, a jest timeout, an unrelated race fix). These belong to whichever step owns them, not to this one.
- **Build artifacts**, especially `worker.bundle.js`. These differ because the worktree's `node_modules` is flatter than the main repo's, not because of any code change. Rebuilding reproduces the difference rather than removing it.
- **The `evidence/` directory**, which is a review artifact and is never committed.
- **Test scaffolding that duplicates existing unit coverage.** See step 5.

State the split, then act on it in step 4. Do not stop to have it approved: removing unrelated work is the job this command was invoked to do, and the user can see what went from the report at the end. On a genuinely borderline call, decide it yourself: say which way you went and why in one line, then carry on. Never ask.

## Step 4: Remove the unrelated changes

- Delete `evidence/` outright.
- Revert source changes by hand with Edit, using `git -C <worktree> diff HEAD -- <file>` as the reference for what to put back. Restore whitespace exactly so the file ends up byte-identical to HEAD.
- For a build artifact you cannot hand-edit, restore it by copying the main repo's copy, but **only after proving they match**:
  ```
  git -C <worktree> rev-parse HEAD:<path>      # the blob the worktree should have
  git hash-object <main-repo>/<path>           # what you are about to copy in
  ```
  Copy only if the hashes are identical. Then note that the artifact is now stale relative to the worktree's `node_modules`, so running the on-device suite from that worktree will regenerate it.
- After each round, confirm with `git -C <worktree> diff HEAD --stat` that the file has dropped off the list.

## Step 5: Challenge the test scaffolding

Ask whether every test the step added earns its keep. A smoke test is worth its cost only if it exercises something the unit tests cannot.

- If the smoke test drives the code against a stub or fake, it is asserting what a unit test already asserts, just more slowly and with more machinery around it. That is a strong signal to delete it.
- Weigh the full cost, not just the test file: a control-bridge route, a registry hook in shared code, a helper module written only to be driven by the test.
- Before deleting, confirm the unit tests genuinely cover every path the smoke test claimed to cover, and name those tests in your report.
- Make the removal decision yourself. Delete only when you have proven the coverage above; otherwise keep the test. Either way, state what you did and the evidence for it. Never ask the user first.

When removing scaffolding, chase down every reference: the test directory, the helper module and its test, the bridge route, any registry or dispatch hook, the import and the export. Grep for the removed symbols afterwards to be sure nothing dangles.

**Hunt down test-only backdoors and rip them out, then drive the test through the real user path instead.** The worst scaffolding is not an extra test file, it is a shortcut wired into production or shared code purely so a test can skip doing what a user would do. A test-only "seed" or "inject" function, a hidden hook that pre-populates state, a special path guarded by a test flag: these exist only because writing the honest test looked like more work. They are almost never necessary, because the app already exposes the real way to reach that state.

- The concrete case that has already happened: the LAN-sharing smoke test added functions to "seed secrets" directly. That was pointless. The app itself adds secrets through its normal UI, so the test should add them the same way a user does. The seeding functions were dead weight bolted onto shared code.
- When you find one, do not just delete the test. Delete the backdoor, then rewrite the test to exercise the genuine feature end to end. A test that goes through the real path is the only kind worth keeping; a test that only works because of a hook it installed itself proves nothing about what the user gets.
- If honestly rewriting the test is genuinely impossible without the hook, say exactly why in one line rather than quietly keeping the backdoor. That is the rare exception, not the default.
- Treat any symbol whose only callers are tests, and which lives in production or shared code, as a suspected backdoor and investigate it on those grounds alone.

## Step 6: Strip the over-engineering

The remaining code is now all on-topic, but on-topic is not the same as necessary. An implementation agent working alone tends to build more than the problem needs. Read what is left and cut it back to the smallest thing that does the job.

Look for:

- **Abstractions with one implementation.** An interface, a store, a provider, or a strategy introduced so a single concrete thing can be swapped. If nothing swaps it, inline it.
- **Helper modules that exist to be called once.** A file of a couple of hundred lines driven by exactly one caller is usually a function.
- **Defensive layers nobody asked for.** Retries, fallbacks, caps, latches, and "this must never break the app" guards added speculatively. This codebase's style is explicit: do not add exception handling unless it was asked for.
- **Comment essays.** A twelve-line block explaining the reasoning behind three lines of code. Keep the sentence that says why; drop the retelling.
- **Logging added to prove the change works.** Useful while debugging, noise afterwards.
- **Options, parameters, and exported symbols with one caller.** Especially anything exported purely so a test can reach it.
- **Reformatting, renaming, and reordering** that came along for the ride. The project rule is to minimise the size of the change, so these belong in the diff only if the fix needed them.

For each thing you cut, check nothing else now references it, and keep the unit tests passing. If removing something would lose real behaviour, keep it and say why in one line.

Where a simplification is a judgement call rather than a clear cut, say what you would do and do it. Do not stop to ask.

## Step 7: Verify

From the worktree, with an absolute path and an explicit timeout:

```
cd <abs-worktree> && mise exec -- bun run compile
cd <abs-worktree> && mise exec -- bun run test
```

Both must exit 0.

**Run the Android smoke suite only once the cheap local checks have passed.** Compile clean and unit tests green before you go near the emulator. Never run it early to "see where things stand", never run it while you still have edits to make, and never run it twice because the first attempt caught something the compiler or unit tests would have caught for free.

The reason is queueing. The emulator is a single machine-wide resource and there are multiple chats lined up for it, each taking a turn. Every minute you hold the lock is a minute every other chat is blocked, and a run you launch on code you have not already verified is a run you will probably have to repeat, sending you to the back of the queue and pushing everyone else back too. So satisfy yourself the code is genuinely correct by the cheap, local, parallel-safe checks first. Acquiring the lock is a claim that you believe this run will pass.

Then run the Android smoke suite, which is the gate that actually proves a mobile change works.

**Run `test:all` and `test:and` in parallel, not one after the other.** Once compile and unit tests are green, launch both and let them run at the same time. They contend for nothing that matters: `test:all` drives CLI processes and Electron windows on the host, while `test:and` drives the emulator over adb. Running them back to back roughly doubles the wall clock of the slowest part of the review for no benefit. Launch each detached with its own sentinel file, then wait on both with `Monitor`. The rule above still holds: do not launch either on code you have not already compiled and unit-tested, because a wasted emulator run is expensive for every other chat.

**There is a single Android emulator, shared by every parallel Claude instance running this command across every worktree.** Two suites on it at once corrupt each other's runs. Because these instances cannot see each other, coordinate through a lock file on a fixed, machine-wide path that every instance agrees on: `/tmp/photosphere-android-emulator.lock`. Do not put the lock inside a worktree or the repo, or parallel instances in different worktrees would each take a different lock and not exclude one another.

**The suite can run longer than any Bash-tool timeout, and a timeout does not stop it.** The Bash tool caps `timeout` at 600000ms (10 minutes). When that cap fires, the Bash call returns to you but the suite keeps running on the emulator, and if it was wrapped in a foreground `flock`, the lock is released the moment the wrapped process is reaped, while the test is still running on the device. A parallel instance then grabs the "free" lock and collides with the run still in progress. So you must never run the suite as a plain foreground call, and never infer pass or fail from a call that hit its timeout. The only proof a run finished is an exit code you observed after the run actually ended.

Instead, **detach the run so it lives independently of your view of it, hold the lock for its true duration, and wait on a condition, not a clock.** Use per-run scratch files in `/tmp` for the log and the exit-code sentinel (keyed by worktree name so parallel worktrees don't clobber each other). Writing these `/tmp` scratch files and the lock is the one allowed exception to "never write outside the worktree"; never write run scratch into the worktree or the repo.

1. Clear stale state so an old sentinel can't read as "done":
   ```
   rm -f /tmp/ps-and-<worktree>.exit /tmp/ps-and-<worktree>.log
   ```
2. Write a tiny detached runner (keeps quoting sane) and launch it in a new session so it survives the Bash call being reaped at timeout. `setsid` detaches it from your process group; `</dev/null` and the redirects free it from any tty. `flock` runs *inside* the detached process, so the lock is held for the real duration of the suite and auto-released only when the suite truly exits (or the process dies):
   ```
   printf '%s\n' '#!/bin/sh' \
     'cd <abs-worktree>' \
     'flock /tmp/photosphere-android-emulator.lock mise exec -- bun run test:and' \
     'echo $? > /tmp/ps-and-<worktree>.exit' > /tmp/ps-and-<worktree>.sh
   setsid sh /tmp/ps-and-<worktree>.sh > /tmp/ps-and-<worktree>.log 2>&1 </dev/null &
   ```
   This launch command returns immediately; it is not the run, it only starts it.
3. **Wait on the sentinel, not on a timeout.** Use the `Monitor` tool with an until-condition that the sentinel file exists (for example `test -f /tmp/ps-and-<worktree>.exit`), with a generous ceiling (45-60 minutes). Do not `sleep` in the foreground and do not poll in a tight loop. The sentinel appears only after `flock` has both acquired the lock and the suite has finished, so this naturally waits out another instance's run too.
4. When the sentinel exists, read the real result: the exit code is the contents of `/tmp/ps-and-<worktree>.exit`, and the pass line is in `/tmp/ps-and-<worktree>.log`. It passes only on **exit code 0 and an "All N tests passed" line**. Anything else is a failure.
5. If the `Monitor` ceiling is reached with no sentinel, the run is still going or wedged. Do **not** report a result and do **not** launch a second run. Say it is still running (or investigate a wedge: `flock` releases a crashed holder's lock automatically, so a persistently missing sentinel points at a hung suite, not a stuck lock), then extend the wait.

- The lock enforces **one run at a time** on the shared emulator; never bypass it by launching the suite without `flock`, and never start a second run while this worktree's sentinel is still pending. Keep one emulator warm rather than rebooting it between runs.
- Removing a smoke test in step 5 changes the expected test count.
- Run this after step 6, not before, so the suites gate the simplification too. Account for that rather than treating a lower number as a regression.

Report the exit code of every suite. Never report a suite as passing without having seen its exit code. A timed-out or still-running Android suite is not a passing suite and not a failing one: it is unfinished, and you say so. If one fails, fix the code, not the test.

## Step 8: Confirm the worktree is now only the core fix

- `git -C <worktree> diff HEAD --stat` and `git -C <worktree> status --porcelain`.
- Walk each remaining file and say why it belongs to the core fix.
- If anything unrelated survives, say so plainly rather than claiming the worktree is clean.

## Step 9: Report the loose ends

Finish by listing anything the user still needs to deal with:

- Plan and checklist entries in the main repo that no longer match what the worktree contains (for example a smoke test that was removed).
- Build artifacts that will need regenerating on the merged branch.
- Files that overlap with other worktrees and will need deduping at merge.
- Any gap in the fix that was deliberately left open.
