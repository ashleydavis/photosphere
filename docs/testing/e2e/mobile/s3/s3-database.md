# Mobile Manual Test: A Database Held in S3

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test opening and using a database whose storage is an S3 bucket rather than the phone.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

An S3 bucket and its credentials. Create the database from `apps/cli/`:

```bash
bun run start -- init --db s3:<bucket>:/manual-test --yes
bun run start -- add ../../test/test.jpg --db s3:<bucket>:/manual-test
```

Send the S3 credentials to the phone as a secret, and the database entry, as in [cli-to-mobile](../lan-share/cli-to-mobile.md).

## Steps

### 1. Open it

1. Open the S3 database on the phone.

Expected:
- The gallery loads and thumbnails appear.
- It is usable on a phone connection, not only on fast Wi-Fi: give it a moment rather than expecting it to be instant.

---

### 2. Import into it

1. Import a photo from the device.

Expected:
- The import completes and the photo appears in the gallery.
- It is in the bucket: check from `apps/cli/` with `bun run start -- list --db s3:<bucket>:/manual-test`.

---

### 3. Open a photo full size

1. Open a photo full screen.

Expected: The full photo loads from S3. A thumbnail that renders while the full photo never arrives is worth noting.

---

### 4. Lose the network mid-use

1. Put the phone in flight mode.
2. Scroll the gallery and open a photo.

Expected:
- The app says it cannot reach the storage.
- It does not crash, and does not show an empty gallery as though the database were empty.

---

### 5. Come back

1. Turn the network back on.
2. Scroll and open a photo again.

Expected: It recovers without the app being restarted.

---

### 6. Wrong credentials

1. Edit the S3 secret to something invalid.
2. Close and reopen the database.

Expected: The app says it cannot authenticate. It does not report an empty database.
