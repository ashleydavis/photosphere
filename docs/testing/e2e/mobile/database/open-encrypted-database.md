# Mobile Manual Test: Open an Encrypted Database

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a database encrypted with a key opens on the phone when the key is in the vault, and refuses when it is not.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

An encrypted database and its key. Create one from `apps/cli/`:

```bash
bun run start -- init --db /tmp/psi-encrypted --key manual-test-key --generate-key --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-encrypted --key manual-test-key
```

Then send the key and the database entry to the phone over the LAN, as in [cli-to-mobile](../lan-share/cli-to-mobile.md).

## Steps

### 1. Open it with the key present

1. Check the key is listed under **Secrets** on the phone.
2. Open the database.

Expected:
- The gallery loads and the photos are shown.
- Thumbnails render rather than showing broken images.

---

### 2. Open a photo

1. Open one of the photos full screen.

Expected: The full photo loads. Decryption happens on the phone, so a photo that shows as a thumbnail and fails full screen is worth noting here.

---

### 3. Open it without the key

1. Delete the key from **Secrets**.
2. Close the database and open it again.

Expected:
- The app says it cannot open the database, or that the key is missing.
- It does not show an empty gallery as though the database had no photos, and it does not crash.

---

### 4. Put the key back

1. Receive the key again.
2. Open the database.

Expected: The photos are back, unchanged.
