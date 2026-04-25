Produce a commit message and description for the current work.

Gather context in priority order, stopping as soon as you have enough to write a good commit message and description:

1. **Conversation context** — if the current conversation clearly describes what was just done, use that and stop here.
2. **Plan file** — if there is a plan file in the working directory (e.g. plan.md, PLAN.md, or similar), read it. If it describes the completed work well enough, use that and stop here.
3. **Git** — as a last resort, run `git diff --cached`, `git diff`, and `git status` to understand what changed.

Then produce two things:

**Commit message** — one short line, plain English, past tense, no period at the end. Should convey the intent of the change, not just describe what files changed. Keep it under 72 characters.

**Commit description** — a longer paragraph or bullet list with more detail: what changed, why, and any notable decisions or trade-offs. This goes in the body of the commit, separated from the subject by a blank line.

Output both clearly labelled so the user can copy them. Do not commit anything — just produce the text.

When you are done, tell the user they can run `/commit:do` to have Claude stage and commit the changes using these details.
