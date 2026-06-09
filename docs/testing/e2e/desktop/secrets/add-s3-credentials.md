# Desktop Manual Test: Add and Edit an S3-Credentials Secret

Test that the **Add secret** dialog stores an `s3-credentials` secret, and that
editing one field updates it, keeps the other fields, and does not add an extra
`label` field.

## Prerequisites

Start the desktop app from source (run from the repo root):

```bash
bun run dev
```

## Steps

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

Then run from the repo root:

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

---

### 4. Confirm the edit in the app and the CLI

1. Click the **View secret** (eye) button on the `s3-creds-1` row.

Then run from the repo root:

```bash
bun run start -- secrets view --name s3-creds-1 --yes
```

Expected:
- `region` is `eu-west-1` (updated).
- `accessKeyId` is `AKIAOLD` (preserved).
- `secretAccessKey` is `OLDSECRET` (preserved).
- There is no `label` field (the UI must not add one on save).
