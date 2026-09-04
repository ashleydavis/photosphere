# Mobile Manual Test: Add S3 Credentials

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test storing S3 credentials on the phone and using them to reach a database in a bucket.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

An S3 bucket, its region and endpoint, and a key pair that can read and write it.

## Steps

### 1. Add the credentials

1. Go to **Secrets** and add a secret of type S3 credentials.
2. Name it `manual-test-s3` and fill in the access key, secret key, region and endpoint.

Expected: It is saved and listed by name.

---

### 2. View it

1. Open the secret.

Expected:
- Each field is shown as you entered it.
- The secret key is hidden until you ask to see it.

---

### 3. Use it

1. Open an S3 database that uses this secret, as in [s3-database](../s3/s3-database.md).

Expected: The gallery loads, which is the only real proof the credentials were stored intact.

---

### 4. Edit it

1. Change the secret key to something wrong and save.
2. Close and reopen the S3 database.

Expected: The app says it cannot authenticate rather than showing an empty gallery.

---

### 5. Put it back

1. Correct the secret key.
2. Open the database again.

Expected: It works again, with no restart of the app needed.
