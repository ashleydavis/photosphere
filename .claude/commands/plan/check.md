Analyse the current plan for problems. Use the plan from the current conversation, or read the most recent file in `docs/plans/` if no plan is in context.

Check each of the following and report findings under labelled headings:

**Missing** — Are there steps that are implied but not stated? Dependencies not accounted for? Edge cases ignored?

**Inconsistencies** — Do any steps contradict each other? Are names, types, or interfaces used inconsistently across steps?

**Issues** — Are there technical problems, flawed assumptions, or approaches likely to cause bugs?

**Tests** — Are unit tests and integration tests called out for each new or changed function? Are edge cases covered?

**Docs** — Does the plan account for updating any relevant documentation, comments, or CLAUDE.md entries?

**Security** — Are there injection risks, auth gaps, secrets handling issues, or other OWASP-class problems introduced by the plan?

For each heading, list findings as bullet points. If nothing was found for a category, write "None identified." Do not suggest fixes — only report findings.

Come up with a list of issues. Write them to a new section at the top of the plan. Give them checkboxes so we can mark them as done before we work through them.