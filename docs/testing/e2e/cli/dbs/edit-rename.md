# CLI Manual Test: `dbs edit` (Rename)

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `dbs edit --new-name` renames a database entry.

## Prep

From the repo root, build the CLI, put it on the PATH, point the CLI at an empty config directory and seed a database entry:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-dbs-edit-rename
mkdir -p /tmp/psi-cli-dbs-edit-rename/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-dbs-edit-rename/config
cat > /tmp/psi-cli-dbs-edit-rename/config/databases.toml <<'TOML'
recent_database_names = []

[[databases]]
name = "edit-db"
description = ""
path = "/tmp/psi-cli-dbs-edit-rename/db"
TOML
```

Expected: no output.

## Test

### 1. Rename it

```bash
psi dbs edit --name edit-db --yes --new-name renamed-db
```

Expected:
- The command exits successfully.

## Check

### 2. Confirm the new name is listed

```bash
psi dbs list
```

Expected:
- Output contains `renamed-db`.
- Output does not contain `edit-db`.
