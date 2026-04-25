Find the root cause of the problem described in the conversation. Do not propose a fix — only identify and prove the root cause.

0. **Choose working location** — ask the user whether to run experiments in the main working copy or a git worktree. If they choose a worktree: (1) run `git branch --show-current` to get the current branch, (2) run `git worktree add -b <new-branch> .claude/worktrees/<name> <current-branch>` to create the worktree branching from the current branch, (3) use `EnterWorktree` with the `path` parameter to enter it, then run `bun install '*'` inside it before proceeding.

1. **Understand the problem** — restate the issue in one sentence so it is unambiguous.

2. **Reproduce the problem** — run the relevant test, command, or minimal script that triggers the failure. Confirm you can see the bad behaviour before investigating further. If you cannot reproduce it, report that clearly and stop.

3. **Explore the codebase** — read the relevant files and trace the call chain. Do not use git.

4. **Experiment** — form a hypothesis about where the fault lives, then test it. Add temporary logs, throw on the suspected bad path, or comment out the suspected faulty code to observe whether the behaviour changes. Repeat with a new hypothesis if the first is disproved. Keep each experiment minimal and targeted.

5. **State the root cause** — once an experiment confirms the fault, give a precise, single-sentence statement of the root cause. Name the file, function, and line number.

6. **Revert** — undo all experimental changes from steps 4 and 5. IMPORTANT: only revert your own experimental changes. Do not revert pre-existing uncommitted changes that were already in the working directory before you started.

7. **Report** — write a short summary:
   - One-sentence root cause statement
   - File, function, and line number
   - How you reproduced it (command or test run and its output)
   - Which experiment proved it and what changed when you ran it
