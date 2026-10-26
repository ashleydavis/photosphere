# CLI Manual Test: `dbs edit` (Rename)

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `dbs edit --new-name` renames a database entry.

## Prep

Move into the CLI source directory, point the CLI at an empty config directory and seed a database entry:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
cat > /tmp/psi-test/config/databases.toml <<'TOML'
recent_database_names = []

[[databases]]
name = "edit-db"
description = ""
path = "/tmp/psi-test/edit-db"
TOML
```

Expected: no output.

## Test

### 1. Rename it

```bash
bun run start -- dbs edit --name edit-db --yes --new-name renamed-db
```

Expected:
- The command exits successfully.

## Check

### 2. Confirm the new name is listed

```bash
bun run start -- dbs list
```

Expected:
- Output contains `renamed-db`.
- Output does not contain `edit-db`.
