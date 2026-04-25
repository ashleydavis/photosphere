Review the current context and changes, then add any missing tests and update any out-of-date documentation.

**Step 1: Gather context**

Review in priority order, stopping as soon as you have enough:

1. **Conversation context** — if the current conversation clearly describes what was just done, use that.
2. **Git** — run `git diff --cached`, `git diff`, and `git status` to understand what changed.

**Step 2: Plan**

Build a todo list with TodoWrite covering:
- Each missing or outdated test to write
- Each documentation file to update (check both this repo and the project wiki, which may be available as an additional working directory)

If nothing is needed in either category, note that explicitly and stop.

**Step 3: Execute**

Work through the todo list item by item, marking each done as you go:
- Write missing or outdated tests following project conventions (Jest, `test(` not `it(`, files under `src/test/`).
- Update any markdown docs in the repo or wiki that are out of date or missing coverage of the changes.

**Step 4: Summarise**

After completing the todo list, summarise what was added or changed.
