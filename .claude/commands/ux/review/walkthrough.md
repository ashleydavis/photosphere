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

- Plain English. No jargon. No made-up terms.
- No waffle. Only what matters.
- Use bullet points.
- Keep it short and easy to understand.

## How to run the walkthrough

Go through ONE finding at a time. Do not dump the whole list.

For each finding, show:

- **What it is** - one or two plain lines.
- **Why it matters** - one line, from a new user's point of view.
- **See it in the screenshot** - the screenshot file (e.g.
  `ux-review/screenshots/02-gallery.png`) and exactly what to look at (e.g.
  "top-right three-dot icon"). Read/open the image so you can describe it.
- **See it live** - the steps to see it in the real app:
  - Start the app: `bun run dev` (from the repo root).
  - Open a test database, e.g. `test/dbs/50-assets`.
  - Then the exact clicks or page to go to (e.g. "open any photo, then click
    Gallery in the top bar - notice it does not return to the grid").

Then stop and wait. Ask the user to say "next" to continue (or to skip, jump, or
stop). Do not move on until they reply.

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
