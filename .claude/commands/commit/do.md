Stage and commit the current changes using the commit message and description already produced in this conversation by `/commit:detz`.

Steps:
1. Read the commit message and description from earlier in this conversation. If they are not present, stop and tell the user to run `/commit:detz` first.
2. Run `git status` to confirm there are changes to commit.
3. Stage all modified and new tracked files using `git add` (list files explicitly — do not use `git add -A` or `git add .`).
4. Commit with the message and description, appending the Co-Authored-By trailer:

```
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

Use a HEREDOC to pass the full commit message so formatting is preserved.

Do not push. Report the commit hash and subject line when done.
