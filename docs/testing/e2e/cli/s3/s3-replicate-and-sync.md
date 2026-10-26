# CLI Manual Test: Replicate to S3 and Sync

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a local database replicates to S3, and that changes on either side then sync across.

The database lives in a local MinIO server started by `bun run s3-emulator` (`scripts/s3-emulator.sh`), the same one the S3 smoke tests use. It needs no account and no credentials of your own, and it binds a free port.

## Prep

Move into the CLI source directory, clean up any previous test run, start the local S3 server, point the CLI at it, and create a local database with a file:

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
bun run start -- init --db /tmp/psi-test/local --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/local --yes
```

Expected:
- The emulator starts, the local database is created and the file is added.

## Test

### 1. Replicate the local database to S3

```bash
bun run start -- replicate --db /tmp/psi-test/local --dest "$S3_DB" --yes
```

Expected:
- `✅ Replication completed successfully`, with files copied.

---

### 2. Compare the two

```bash
bun run start -- compare --db /tmp/psi-test/local --dest "$S3_DB" --yes
```

Expected:
- `No differences detected`.

---

### 3. Add a file on each side, then sync

```bash
bun run start -- add ../../test/test.png --db /tmp/psi-test/local --yes
bun run start -- add ../../test/multiple-files/test-1.jpeg --db "$S3_DB" --yes
bun run start -- sync --db /tmp/psi-test/local --dest "$S3_DB" --yes
```

Expected:
- Both adds show `Files added: 1`.
- The sync reports `Sync completed successfully`.

## Check

### 4. Confirm both sides hold all three files and match

```bash
bun run start -- list --db /tmp/psi-test/local --yes
bun run start -- list --db "$S3_DB" --yes
bun run start -- root-hash --db /tmp/psi-test/local
bun run start -- root-hash --db "$S3_DB"
```

Expected:
- Both lists show `test.jpg`, `test.png` and `test-1.jpeg`.
- The two root hashes are identical.

---

### Stop the S3 server

Run this even when an earlier step failed:

```bash
(cd ../.. && bun run s3-emulator stop /tmp/psi-test/s3)
```

Expected:
- The command exits successfully.
