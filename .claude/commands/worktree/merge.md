Bring changes from a git worktree back into the current branch by merging its branch, then remove the worktree.

Steps:

1. Run `git worktree list --porcelain` to identify all active worktrees. Show the list to the user.

2. If a worktree was used in the current session, use that one. Otherwise, if there is only one non-main worktree, use that one. If there are multiple and it's unclear which to use, ask the user which worktree to merge from (show the path and branch for each).

3. Check for uncommitted changes in the chosen worktree by running `git -C <worktree-path> status --short`. If there are uncommitted changes, run `/commit:detz` to produce a commit message and description, then show it to the user and wait for their approval before running `/commit:do` to stage and commit them inside the worktree.

4. Note the branch name of the worktree (from `git worktree list --porcelain`).

5. Ask the user to confirm before proceeding: show them the worktree path, its branch, and the current branch that will receive the merge.

6. Once confirmed, merge the worktree branch into the current branch:
   ```
   git merge <worktree-branch> --no-ff -m "Merge worktree branch '<worktree-branch>'"
   ```

7. If the merge succeeds, remove the worktree:
   ```
   git worktree remove <worktree-path>
   ```

8. Report success by running these two commands:
   - `git log -1 --oneline` — show the merge commit hash
   - `git worktree list` — confirm the worktree has been removed

   Report the output of both commands to the user. Do not run any other commands.

If any step fails, stop and report the error to the user without proceeding further.
