Create a new plan and save it to `docs/plans/`.

1. **Gather intent** — if the user has described the feature or change in this conversation, use that. Otherwise ask: "What do you want to plan?" Wait for their answer before continuing.

2. **Research** — explore the relevant parts of the codebase to understand the current structure, affected files, and any existing patterns that the plan should follow. Use file reads, grep, and directory listings as needed.

3. **Draft the plan** — produce a complete plan using the structure below. Be specific: name actual files, functions, types, and interfaces. Steps should be small enough to implement one at a time.

```
# <Plan Title>

## Overview
<One paragraph describing the intent and why the change is needed>

## Issues
<Leave empty — populated later by plan:check>

## Steps
<Numbered list of concrete implementation steps, each naming the file and function to change>

## Unit Tests
<List of unit tests to write or update, one per new or changed function>

## Smoke Tests
<List of end-to-end or manual checks that confirm the feature works>

## Verify
<Concrete, observable checks to confirm after implementation — test commands, compile checks, manual steps>

## Notes
<Decisions, trade-offs, open questions, or constraints discovered during research>
```

4. **Choose a filename** — derive a short kebab-case name from the plan subject (e.g. `plan-add-user-auth.md`). If a file with that name already exists in `docs/plans/new/`, choose a different name.

5. **Save** — write the plan to `docs/plans/new/<filename>`.

6. **Report** — print the path of the saved file and a one-line summary of what the plan covers.
