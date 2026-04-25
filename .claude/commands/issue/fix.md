Given the root cause, proposed fix, and implementation plan from this conversation, implement the fix and verify it.

0. **Choose working location** — ask the user whether to implement in the main working copy or a git worktree. If they choose a worktree: (1) run `git branch --show-current` to get the current branch, (2) run `git worktree add -b <new-branch> .claude/worktrees/<name> <current-branch>` to create the worktree branching from the current branch, (3) use `EnterWorktree` with the `path` parameter to enter it, then run `bun install '*'` inside it before proceeding.

1. **Read the plan** — find the plan in context or read the most recent file from `docs/plans/`.

2. **Check for open issues** — if the plan file has an issues section with unchecked checkboxes (`- [ ]`), stop and report them to the user before proceeding.

3. **Create a todo list** — use TodoWrite to break the plan into discrete tasks. Work through them one by one, marking each complete as you finish it.

4. **Implement** — make only the changes described in the plan. Do not add unrequested features, refactoring, or cleanup beyond what the plan specifies.

5. **Verify** — once all tasks are done, run `/verify` to confirm the full test suite and compile checks pass.

6. **Report** — once all checks pass, summarise what was changed (files and functions) and confirm that compile, unit tests, and smoke tests all passed.
