# Mobile Manual Test: Deleting the Photo After it is Backed Up

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test the cleanup setting: once a photo is confirmed in the database, the copy in the device photo library is offered for deletion.

This test destroys photos on the device, on purpose. Run it on a test device or with photos you are willing to lose, and never on a phone holding anything you care about.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

Automatic import already working, as in [the full flow test](auto-import-full-flow.md). Put two throwaway photos in the device library that you can tell apart from the rest.

## Steps

### 1. Turn cleanup on

1. Open the menu and choose **Configuration**.
2. In the **Automatic import** card, turn the cleanup toggle on.

Expected: The setting stays on. Nothing is deleted yet on its own.

---

### 2. Back up a photo and let it be deleted

1. Take a photo, or wait for one of the throwaway photos to be backed up.
2. When the system asks whether to delete the photo from the library, allow it.

Expected:
- The photo disappears from the device photo library, checked in the system gallery app.
- The photo is still in the Photosphere gallery. It was moved, not lost.

---

### 3. Refuse the deletion

1. Wait for the second throwaway photo to be backed up.
2. When the system asks whether to delete it, refuse.

Expected:
- The photo stays in the device photo library.
- The photo is in the Photosphere gallery as well. Refusing the deletion does not undo the backup.
- The app does not ask again in a loop for the same photo while it keeps running.

---

### 4. A photo that failed to import is never deleted

1. Turn automatic import off.
2. Put a file in the device photo library that is not a real image: copy any small file and rename it to end in `.jpg`.
3. Turn automatic import back on and wait for it to be walked past.

Expected:
- The file is **not** deleted from the device library.
- The gallery does not show a broken entry for it.

This is the case that matters most: deletion has to follow the photo actually being in the database, not the import merely reporting it tried.

---

### 5. Check what survived

Share or replicate the database to your development machine, then from `apps/cli/`:

```bash
bun run start -- verify --db <path to the copy>
```

Expected:
- Verification completes without errors.
- Every photo that was deleted from the device is present and intact in the database.

A photo deleted from the device and missing here is the one unrecoverable failure this feature can have, which is why this step is not optional.
