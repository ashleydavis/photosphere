# Mobile Manual Test: Move a Photo Between Databases

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test moving a photo from one database to another, and that it arrives whole and leaves the first.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

Two databases listed on the phone, the first with a photo you will recognise.

## Steps

### 1. Move a photo

1. Open the first database and find the photo.
2. Move it to the second database.

Expected:
- The app says the move completed.
- The photo is gone from the first database's gallery.

---

### 2. Check it arrived

1. Open the second database.

Expected:
- The photo is there.
- Opening it full screen shows the whole photo, not a broken thumbnail. A move that copies the record without the content looks fine in the gallery and fails here.

---

### 3. Check it left

1. Open the first database again.

Expected: The photo is still gone, after the database has been closed and reopened rather than only in the view that was on screen.

---

### 4. Check both databases are sound

Share or replicate both to your development machine, then from `apps/cli/`:

```bash
bun run start -- verify --db <the first>
bun run start -- verify --db <the second>
```

Expected: Both verify with no failures. A move that leaves the source database referring to content it no longer has is the failure this step catches.
