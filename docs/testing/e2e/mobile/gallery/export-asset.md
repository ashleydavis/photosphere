# Mobile Manual Test: Export a Photo Out of the App

Test sending a photo from the database back out to the device, through the system share sheet.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

A database open with at least one photo in it.

## Steps

### 1. Export a photo

1. Go to the gallery and open a photo.
2. Use the download or share action.
3. Choose somewhere to save it, such as Files or Downloads.

Expected:
- The system share sheet appears.
- The photo is saved where you chose, and opens correctly in the system gallery or file browser.
- It is the full photo, not the thumbnail: the file size matches what the info panel shows.

---

### 2. Cancel an export

1. Open a photo and start the export again.
2. Dismiss the share sheet without choosing anything.

Expected:
- The app says the download was cancelled, or simply returns to the photo.
- No error is shown, and nothing is left behind on the device.

---

### 3. Export a video

1. Open a video in the gallery and export it.

Expected: The video is saved and plays back from the device.
