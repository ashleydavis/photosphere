Given the root cause and the chosen proposed fix from this conversation, produce a detailed implementation plan and save it to `docs/plans/`.

1. **Identify the chosen fix** — read the root cause and proposed fixes from the conversation. If it is unclear which numbered fix was chosen, ask the user for clarification before continuing.

2. **Write the plan** — the plan must include:
   - A one-sentence summary of the problem and chosen fix
   - Step-by-step implementation tasks, each naming the file and function to change
   - Unit tests to add or update for every changed function
   - A verification section with these steps in order:
     1. `bun run compile` — if it fails, fix the compile errors before continuing
     2. `bun run test` — if it fails, fix the failing tests before continuing
     3. `bun run test:cli` — if it fails, fix the failures before continuing

3. **Save the plan** — write it as a markdown file to `docs/plans/` using a short descriptive filename (e.g. `docs/plans/fix-credential-lookup.md`).

4. **Report** — state the filename where the plan was saved.
