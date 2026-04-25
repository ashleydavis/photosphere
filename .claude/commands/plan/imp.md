Implement the current plan.

0. **Choose the plan** — if a specific plan is obvious from the conversation context, use that. Otherwise list the 5 most recent files in `docs/plans/new/` (by modification time) and present them as a numbered menu for the user to choose from. Wait for the user's selection before continuing.

1. **Choose working location** — ask the user whether to implement in the main working copy or a git worktree. If they choose a worktree: (1) run `git branch --show-current` to get the current branch, (2) run `git worktree add -b <new-branch> .claude/worktrees/<name> <current-branch>` to create the worktree branching from the current branch, (3) use `EnterWorktree` with the `path` parameter to enter it, then run `bun install '*'` inside it before proceeding.

2. **Read the plan** — read the chosen plan file from `docs/plans/new/`.

3. **Check for open issues** — look at the top of the plan file for an issues section with checkboxes. If any unchecked items (`- [ ]`) exist, stop and report them to the user before proceeding. Only continue if all issues are checked off (`- [x]`).

4. **Create a todo list** — use TodoWrite to break the plan into discrete tasks, then work through them one by one, marking each complete as you go.

5. **Write tests** — add or update unit tests and smoke tests for every new or changed function as described in the plan.

6. **Verify** — once all steps are done, run `/verify` to confirm the full test suite and compile checks pass.

7. **Move the plan** — move the plan file from `docs/plans/new/` to `docs/plans/done/`.

8. **Report** — summarise what was implemented and flag anything that was skipped or deferred.
