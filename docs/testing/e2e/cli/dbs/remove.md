# CLI Manual Test: `dbs remove --yes`

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `dbs remove --yes` removes a database entry from the list and leaves
the other entries untouched.

## Prep

From the repo root, build the CLI, put it on the PATH, point the CLI at an empty config directory and seed two database entries:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-dbs-remove
mkdir -p /tmp/psi-cli-dbs-remove/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-dbs-remove/config
cat > /tmp/psi-cli-dbs-remove/config/databases.toml <<'TOML'
recent_database_names = []

[[databases]]
name = "keep-db"
description = ""
path = "/tmp/psi-cli-dbs-remove/keep-db"

[[databases]]
name = "remove-db"
description = ""
path = "/tmp/psi-cli-dbs-remove/remove-db"
TOML
```

Expected: no output.

## Test

### 1. Remove one entry

```bash
psi dbs remove --name remove-db --yes
```

Expected:
- The command exits successfully.

## Check

### 2. Confirm the listing

```bash
psi dbs list
```

Expected:
- Output contains `keep-db`.
- Output does not contain `remove-db`.
