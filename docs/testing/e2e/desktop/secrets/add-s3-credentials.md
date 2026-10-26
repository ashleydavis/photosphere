# Desktop Manual Test: Add and Edit an S3-Credentials Secret

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that the **Add secret** dialog stores an `s3-credentials` secret and that
editing one field updates it, keeps the other fields and does not add an extra
`label` field.

## Prep

Open two terminals at the repo root, one for the desktop app and one for the CLI.

In either terminal, clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-add-s3-credentials
```

Run this in both terminals. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-add-s3-credentials/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-add-s3-credentials/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-add-s3-credentials/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-add-s3-credentials/logs
export XDG_DATA_HOME=/tmp/psi-desktop-add-s3-credentials/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-add-s3-credentials/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

In the app's terminal, start the desktop app from the repo root. Use the script for the platform you are on: `bun run linux`, `bun run macos` or `bun run windows`. It keeps running for the whole test:

```bash
bun run linux
```

In the CLI terminal, move into the CLI source directory:

```bash
cd apps/cli/
```

Expected:
- The cleanup prints nothing.
- The desktop app window opens.

## Test

### 1. Add a new s3-credentials secret

1. Navigate to the **Manage Secrets** page.
2. Click **Add secret**.
3. Type `s3-creds-1` into the name field.
4. Set the **Type** to `s3-credentials`.
5. Fill the fields:
   - **Region**: `us-east-1`
   - **Access Key ID**: `AKIAOLD`
   - **Secret Access Key**: `OLDSECRET`
6. Click **Save**.

Expected:
- The dialog closes.
- The Manage Secrets page lists `s3-creds-1`.

---

### 2. Confirm the value in the app and the CLI

1. Click the **View secret** (eye) button on the `s3-creds-1` row.

Then run in the CLI terminal:

```bash
bun run start -- secrets view --name s3-creds-1 --yes
```

Expected:
- The view dialog shows `region: us-east-1`, `accessKeyId: AKIAOLD`, `secretAccessKey: OLDSECRET`.
- The CLI output shows the same three fields and no `label` field.

---

### 3. Edit the region

1. Click the **Edit** button on the `s3-creds-1` row.
2. Change the **Region** field to `eu-west-1`.
3. Click **Save**.

Expected:
- The dialog closes without errors.

## Check

### 4. Confirm the edit in the app and the CLI

1. Click the **View secret** (eye) button on the `s3-creds-1` row.

Then run in the CLI terminal:

```bash
bun run start -- secrets view --name s3-creds-1 --yes
```

Expected:
- `region` is `eu-west-1` (updated).
- `accessKeyId` is `AKIAOLD` (preserved).
- `secretAccessKey` is `OLDSECRET` (preserved).
- There is no `label` field (the UI must not add one on save).
