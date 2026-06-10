---
description: Walk the user through the UX review one finding at a time. For each item, explain it simply, point to the screenshot, and tell them how to see it live in the running app.
---

# Walk through the UX review

Take the user through the UX review in `ux-review/review.md`, one finding at a
time. For each finding, explain it, show where to see it in the screenshot, and
tell them how to see it live in the app.

## Before you start

- Read `ux-review/review.md`.
- If it does not exist, tell the user to run `/ux:review:create` first, then stop.
- Build a list of the findings, in order (highest severity first).

## Style for everything you say

The user does not want waffle. They want clear, direct, concise advice. This is
the most important rule here. If in doubt, cut words.

- Plain English. No jargon. No made-up terms.
- No waffle. Only what matters.
- Use bullet points.
- Keep it short and easy to understand.
- One line per labelled part. No sub-bullets. Max ~6 lines per finding.

## How to run the walkthrough

Once, before the first finding, tell the user how to start the app:

- Start the app: `bun run dev` (from the repo root).
- Open a test database, e.g. `test/dbs/50-assets`.

Then go through ONE finding at a time. Do not dump the whole list.

For each finding, show:

- **What it is** - one plain line.
- **Why it matters** - one line, from a new user's point of view.
- **See it in the screenshot** - the screenshot file and exactly what to look
  at. Read/open the image so you can describe it.
- **See it live** - only the unique clicks for this finding (the app is already
  running from the intro above).

Then stop and wait. Ask the user to say "next" to continue (or to skip, jump, or
stop). Do not move on until they reply.

### Example of a good finding

This is the shape and length to aim for. Clear, direct, no waffle.

```
## Finding 1 of 14 🔴 (High)

**The "Gallery" link can't close an open photo**

- What it is: clicking "Gallery" while viewing a photo does nothing.
- Why it matters: the user feels stuck; the obvious way back looks broken.
- Screenshot: `ux-review/screenshots/03-asset-detail.png` - top-left, the only exit is a small "X".
- See it live: open any photo, click "Gallery" in the top bar - nothing happens.

Say "next" to continue.
```

## Mapping findings to live steps

Use the route or screen named in the finding to tell the user where to look.
Common screens and how to reach them in the app:

- Gallery: the main grid after a database is open.
- A photo: click (long press) any thumbnail in the gallery.
- Import: "Import" in the top bar.
- Map: "Map" in the top bar.
- Manage Databases / Manage Secrets: the left menu (hamburger, top-left).
- Search / sort panel: the three-dot button, top-right.
- About / News: the left menu.
- First-run screen: only shows when no database is open.

If a finding does not map to an obvious screen, use the screenshot name (the
number prefix shows the order they were captured in).

## At the end

- Give a short recap: the top 3 things to fix.
- Remind them the review can be re-run with `/ux:review:create`.
