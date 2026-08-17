# Mobile Manual Test: Download Assets to the Device

Test pulling photos out of a database onto the phone, one at a time and several at once.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

A database open with several photos in it.

## Steps

### 1. Download one photo

1. Open a photo in the gallery.
2. Download it to the device.

Expected:
- It is saved where you chose.
- It appears in the device's own gallery app.
- It is the full photo: the file size matches what the info panel shows.

---

### 2. Download several at once

1. Select several photos in the gallery.
2. Download them together.

Expected:
- Progress is shown while it runs.
- Every photo you selected arrives, not just the first.
- The names do not collide: two photos with the same name both land, rather than one overwriting the other.

---

### 3. Download a video

1. Select a video and download it.

Expected: It saves and plays back from the device.

---

### 4. Cancel partway

1. Start a download of several large photos and cancel it.

Expected:
- The app stops and says so.
- What had already been saved is still there, and the app is usable straight away.
