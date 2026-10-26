# CLI Manual Test: `dbs view`

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `dbs view` shows the full details (name, path, secret IDs) of a
database entry.

## Prep

Move into the CLI source directory, point the CLI at an empty config directory and seed a database entry with linked secrets:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
cat > /tmp/psi-test/config/databases.toml <<'TOML'
recent_database_names = []

[[databases]]
name = "view-db"
description = "A test database"
path = "/tmp/psi-test/view-db"
encryption_key = "enc00001"
s3_key = "s3test01"
TOML
```

Expected: no output.

## Test

### 1. View the entry

```bash
bun run start -- dbs view --name view-db
```

Expected output contains all of:
- `view-db` (the name).
- `/tmp/psi-test/view-db` (the path).
- `enc00001` (the encryption key id).
- `s3test01` (the S3 credential id).

## Check

The view output in step 1 is the check.
