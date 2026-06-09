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

1. Click **Open database**. It is on the startup screen (when no database is
   loaded), in the left side menu, and in the **File > Open Database...** menu
   (Ctrl/Cmd+O). All of these open the **Open Database** dialog.
2. The **Open Database** dialog lists databases you have already configured.
   - If `50-assets` is already listed, click it and skip to the expected result.
   - Otherwise click **Add database** to register it first.
3. In the **Add Database** dialog:
   - **Name**: enter `50-assets`.
   - **Type**: leave as **File system**.
   - **Path**: click **Browse** and select `test/dbs/50-assets/` (relative to
     the repo root), or type the path directly.
   - Click **Add**. This registers the database and opens it.

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
