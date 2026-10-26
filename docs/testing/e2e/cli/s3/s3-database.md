# CLI Manual Test: Database on S3

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a database can be created on S3, have a file added, and be listed and verified there.

The database lives in a local MinIO server started by `bun run s3-emulator` (`scripts/s3-emulator.sh`), the same one the S3 smoke tests use. It needs no account and no credentials of your own, and it binds a free port.

## Prep

Move into the CLI source directory, clean up any previous test run, start the local S3 server and point the CLI at it:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
(cd ../.. && bun run s3-emulator start /tmp/psi-test/s3)
source /tmp/psi-test/s3/env
export AWS_ACCESS_KEY_ID="$S3_EMULATOR_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_EMULATOR_SECRET_KEY"
export AWS_ENDPOINT="http://127.0.0.1:$S3_EMULATOR_PORT"
export S3_DB="s3:$S3_EMULATOR_BUCKET/manual-test"
```

Expected:
- The emulator starts and `/tmp/psi-test/s3/env` exists.

## Test

### 1. Create a database on S3

```bash
bun run start -- init --db "$S3_DB" --yes
```

Expected:
- Output confirms a new media file database was created at the `s3:` path.

---

### 2. Add a file to it

```bash
bun run start -- add ../../test/test.jpg --db "$S3_DB" --yes
```

Expected:
- Output shows `Files added: 1` and `Files failed: 0`.

## Check

### 3. List and verify the S3 database

```bash
bun run start -- list --db "$S3_DB" --yes
bun run start -- verify --db "$S3_DB" --yes
```

Expected:
- `test.jpg` is listed.
- Verification passes with `Files imported: 1`.

---

### Stop the S3 server

Run this even when an earlier step failed:

```bash
(cd ../.. && bun run s3-emulator stop /tmp/psi-test/s3)
```

Expected:
- The command exits successfully.
