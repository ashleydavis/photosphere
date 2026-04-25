Summarise the current plan. Use the plan from the current conversation, or read the most recent file in `docs/plans/new/` if no plan is in context.

Produce two things:

**Summary** — one paragraph describing the intent of the plan in plain English. What problem does it solve? What will change? Why is the change needed?

**Verification checklist** — a bullet list of things to confirm after implementation is complete. Cover unit tests, smoke tests, and any ad-hoc manual checks. Each item should be a concrete, observable check (e.g. "unit tests pass for `editSecret`", "CLI command `secrets edit` accepts multiline input", "manually verify the modal closes after save").
