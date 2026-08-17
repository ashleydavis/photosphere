# Mobile Manual Test: View a Database's Details

Test the database summary: what the app says a database holds, and that it agrees with the gallery.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

A database open with a few photos in it.

## Steps

### 1. Open the summary

1. Open the side menu.
2. Choose the database summary.

Expected:
- The number of assets is shown and matches the gallery.
- The total size is shown.
- The database's own hash or identifier is shown.

---

### 2. Check it changes with the database

1. Import another photo.
2. Open the summary again.

Expected: The asset count has gone up by one, and the size has grown.

---

### 3. Check it against the CLI

Share or replicate the database to your development machine, then from `apps/cli/`:

```bash
bun run start -- summary --db <path to the copy>
```

Expected: The counts agree with what the phone showed. A phone that reports more assets than the database holds is reporting its own memory rather than the database.
