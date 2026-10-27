# CLI Manual Test: `dbs view`

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `dbs view` shows the full details (name, path, secret IDs) of a
database entry.

## Prep

From the repo root, build the CLI, put it on the PATH, point the CLI at an empty config directory and seed a database entry with linked secrets:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-dbs-view
mkdir -p /tmp/psi-cli-dbs-view/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-dbs-view/config
cat > /tmp/psi-cli-dbs-view/config/databases.toml <<'TOML'
recent_database_names = []

[[databases]]
name = "view-db"
description = "A test database"
path = "/tmp/psi-cli-dbs-view/view-db"
encryption_key = "enc00001"
s3_key = "s3test01"
TOML
```

Expected: no output.

## Test

### 1. View the entry

```bash
psi dbs view --name view-db
```

Expected output contains all of:
- `view-db` (the name).
- `/tmp/psi-cli-dbs-view/view-db` (the path).
- `enc00001` (the encryption key id).
- `s3test01` (the S3 credential id).

## Check

The view output in step 1 is the check.
