# CLI Manual Test: `dbs clear --yes`

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `dbs clear --yes` empties the database list entirely.

## Prep

From the repo root, build the CLI, put it on the PATH, point the CLI at an empty config directory, seed two database entries and confirm both are listed:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-dbs-clear
mkdir -p /tmp/psi-cli-dbs-clear/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-dbs-clear/config
cat > /tmp/psi-cli-dbs-clear/config/databases.toml <<'TOML'
recent_database_names = []

[[databases]]
name = "db-one"
description = ""
path = "/tmp/psi-cli-dbs-clear/db-one"

[[databases]]
name = "db-two"
description = ""
path = "/tmp/psi-cli-dbs-clear/db-two"
TOML
psi dbs list
```

Expected:
- The list shows `db-one` and `db-two`, so the clear below has something to remove.

## Test

### 1. Clear all entries

```bash
psi dbs clear --yes
```

Expected:
- The command exits successfully and reports that 2 databases were removed.

## Check

### 2. Confirm the list is empty

```bash
psi dbs list
```

Expected:
- Output contains `No databases`.
- Output does not contain `db-one` or `db-two`.
