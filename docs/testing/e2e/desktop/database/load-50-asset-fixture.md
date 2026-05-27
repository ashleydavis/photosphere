# Desktop Manual Test: Load the 50-Asset Fixture

Test that the desktop app loads the repo's pre-populated 50-asset database and
renders the gallery with all assets visible.

## Prerequisites

Start the desktop app from source (run from the repo root):

```bash
bun run dev
```

## Steps

### 1. Open the fixture in the desktop app

1. In the desktop app, choose **Open database**.
2. Browse to `test/dbs/50-assets/` (relative to the repo root) and open it.

Expected:
- The gallery loads and displays exactly 50 thumbnails.
- No error toasts are shown.

---

### 2. Spot-check that thumbnails and previews render

- Scroll through the gallery and confirm the thumbnails are visible.
- Click on any asset to open its detail view and confirm the larger preview renders.

Expected:
- All 50 thumbnails are visible (no broken-image placeholders).
- The detail view opens for each asset clicked, showing a larger preview and metadata.
