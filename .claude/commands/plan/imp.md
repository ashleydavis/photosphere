Implement the current plan. Use the plan from the current conversation, or read the most recent file in `docs/plans/` if no plan is in context.

1. **Read the plan** — if not already in context, find and read the relevant file from `docs/plans/`.

2. **Check for open issues** — look at the top of the plan file for an issues section with checkboxes. If any unchecked items (`- [ ]`) exist, stop and report them to the user before proceeding. Only continue if all issues are checked off (`- [x]`).

3. **Create a todo list** — use TodoWrite to break the plan into discrete tasks, then work through them one by one, marking each complete as you go.

4. **Write tests** — add or update unit tests and smoke tests for every new or changed function as described in the plan.

5. **Verify** — once all steps are done, run `/verify` to confirm the full test suite and compile checks pass.

6. **Report** — summarise what was implemented and flag anything that was skipped or deferred.
