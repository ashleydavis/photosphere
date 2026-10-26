# CLI Manual Test: `dbs clear --yes`

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `dbs clear --yes` empties the database list entirely.

## Prep

Move into the CLI source directory, point the CLI at an empty config directory, seed two database entries and confirm both are listed:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
cat > /tmp/psi-test/config/databases.toml <<'TOML'
recent_database_names = []

[[databases]]
name = "db-one"
description = ""
path = "/tmp/psi-test/db-one"

[[databases]]
name = "db-two"
description = ""
path = "/tmp/psi-test/db-two"
TOML
bun run start -- dbs list
```

Expected:
- The list shows `db-one` and `db-two`, so the clear below has something to remove.

## Test

### 1. Clear all entries

```bash
bun run start -- dbs clear --yes
```

Expected:
- The command exits successfully and reports that 2 databases were removed.

## Check

### 2. Confirm the list is empty

```bash
bun run start -- dbs list
```

Expected:
- Output contains `No databases`.
- Output does not contain `db-one` or `db-two`.
