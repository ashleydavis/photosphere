# Running a UX Review

How to run a UX review of the Photosphere desktop app and walk through the
results.

## What it does

- Looks at the desktop app as a brand-new user would.
- Takes screenshots of the main screens.
- Writes up problems and suggestions.
- Output goes to `ux-review/` (gitignored, never committed).

## Run a review

Use the skill:

```
/ux:review:create
```

This will:

- Capture screenshots (runs `bun run screenshots` under the hood).
- Analyse each screen from a new user's point of view.
- Write the review to `ux-review/review.md`.
- Save screenshots to `ux-review/screenshots/`.

You can run it again any time. It overwrites the previous output.

## Walk through the results

Use the skill:

```
/ux:review:walkthrough
```

This goes through the review one finding at a time. For each item it tells you:

- What it is and why it matters.
- Which screenshot shows it, and what to look at.
- How to see it live in the running app.

It stops after each item and waits for you to say "next".

## Just the screenshots

To only capture screenshots (no review write-up):

```bash
bun run screenshots
```

Screenshots are written to `ux-review/screenshots/`.

## More detail

- Screenshot tooling and how the capture works: [testing/screenshots.md](testing/screenshots.md)
- The review process itself: `.claude/commands/ux/review/create.md`
- The walkthrough process: `.claude/commands/ux/review/walkthrough.md`
