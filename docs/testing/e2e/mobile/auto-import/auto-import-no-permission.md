# Mobile Manual Test: Automatic Import Without the Photo Permission

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that refusing the photo permission is said out loud rather than leaving the feature switched on and doing nothing.

A user who taps "Don't allow" and then sees the toggle sitting on has been told the backup is running when it cannot run at all.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

Start with the app's data cleared, and with the photo permission not yet granted. On Android: **Settings > Apps > Photosphere > Permissions > Photos and videos > Don't allow**. On iOS: **Settings > Photosphere > Photos > None**.

## Steps

### 1. Switch automatic import on and refuse the permission

1. Open the menu and choose **Configuration**.
2. Find the **Automatic import** card.
3. Turn the toggle on.
4. When the system asks for permission to read your photos, refuse it.

Expected:
- The toggle switches itself back off.
- A message says the app needs permission to read your photos.
- No database is created: **Open database** lists nothing new.

---

### 2. Grant the permission and try again

1. Grant the photo permission in the system settings for the app.
2. Return to Photosphere and turn the **Automatic import** toggle on again.

Expected:
- The toggle stays on this time.
- The app creates its database and starts backing up, as in [the full flow test](auto-import-full-flow.md).

---

### 3. Take the permission away while it is running

1. Leave automatic import on.
2. In the system settings for the app, revoke the photo permission.
3. Return to Photosphere.

Expected:
- The app does not crash, and does not sit reporting progress it cannot be making.
- Automatic import stops, and the app says why.

Note what actually happens here if it differs: the app may be restarted by the operating system when a permission is revoked, which is the system's doing rather than the app's.
