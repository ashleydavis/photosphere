Given the root cause, proposed fix, and implementation plan from this conversation, implement the fix and verify it.

1. **Read the plan** — find the plan in context or read the most recent file from `docs/plans/`.

2. **Check for open issues** — if the plan file has an issues section with unchecked checkboxes (`- [ ]`), stop and report them to the user before proceeding.

3. **Create a todo list** — use TodoWrite to break the plan into discrete tasks. Work through them one by one, marking each complete as you finish it.

4. **Implement** — make only the changes described in the plan. Do not add unrequested features, refactoring, or cleanup beyond what the plan specifies.

5. **Verify** — once all tasks are done, run the following checks in order:
   1. `bun run compile` — if it fails, fix the compile errors and re-run before continuing
   2. `bun run test` — if it fails, fix the failing tests and re-run before continuing
   3. `bun run test:cli` — if it fails, fix the failures and re-run before continuing

6. **Report** — once all checks pass, summarise what was changed (files and functions) and confirm that compile, unit tests, and smoke tests all passed.
