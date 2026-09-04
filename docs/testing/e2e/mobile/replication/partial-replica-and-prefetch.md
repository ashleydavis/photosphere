# Mobile Manual Test: A Partial Replica and Fetching Originals Back

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test a database on the phone that holds only part of what the remote holds: the gallery still shows everything, and an original is fetched back when it is opened.

This is what lets a phone carry a collection larger than the phone.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

A database on the phone whose origin is a remote copy holding photos the phone has not downloaded, as in [edit-database-origin](../database/edit-database-origin.md). An S3 database is the easiest way to get one.

## Steps

### 1. See what the remote holds

1. Open the database on the phone and let it sync.

Expected:
- The gallery shows every photo in the remote, including ones whose originals are not on the phone.
- Thumbnails appear for them.

---

### 2. Open one the phone does not hold

1. Open a photo whose original has not been downloaded.

Expected:
- The full photo is fetched and shown.
- It takes longer than one already on the phone, and says so or shows progress rather than appearing to hang.

---

### 3. Open it again

1. Close the photo and open it again.

Expected: It appears immediately the second time.

---

### 4. Open one with no network

1. Put the phone in flight mode.
2. Open a photo whose original is not on the phone.

Expected:
- The app says it cannot fetch it.
- It does not show a blank screen with no explanation, and the photos the phone does hold still open.

---

### 5. Check the phone did not lose the remote's photos

1. Turn the network back on and let it sync.

From `apps/cli/`:

```bash
bun run start -- summary --db <the remote>
```

Expected: The remote still holds everything it did. A phone that holds part of a database must never delete from the remote what it chose not to download.
