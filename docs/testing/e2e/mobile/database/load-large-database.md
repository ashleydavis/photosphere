# Mobile Manual Test: Open a Database With Many Photos

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test the app against a database large enough to show whether the gallery scrolls, loads and stays usable on a phone.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

A database with at least fifty photos in it. Build one from `apps/cli/`:

```bash
bun run start -- init --db /tmp/psi-large --yes
bun run start -- add ../../test/multiple-files --db /tmp/psi-large
```

Send the entry to the phone, or point the phone at it in S3.

## Steps

### 1. Open it

1. Open the database on the phone.

Expected:
- The gallery appears without the app freezing.
- Thumbnails fill in as they load rather than the screen staying blank until every one is ready.

---

### 2. Scroll it

1. Scroll from the top to the bottom and back.

Expected:
- Scrolling stays smooth.
- Thumbnails load as you go and do not disappear again once loaded.
- No photo shows as broken.

---

### 3. Open photos from the middle and the end

1. Open a photo from partway down, and one from the very end.

Expected: Both load full screen.

---

### 4. Leave and come back

1. Send the app to the background, use another app, and come back.

Expected: The gallery is where you left it and is still usable, rather than reloading from the top or showing an empty screen.

---

### 5. Check nothing was lost

1. Open the database summary.

Expected: The count matches what the CLI reports for the same database with `bun run start -- summary`.
