# CLI Manual Test: `dbs add` Then `dbs list`

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that adding an entry makes it appear in the listing.

## Prep

From the repo root, build the CLI, put it on the PATH, point the CLI at an empty config directory and add a database entry by seeding `databases.toml` directly (the smoke-test runner does the same with a `seed_databases_config` helper):

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-dbs-add-and-list
mkdir -p /tmp/psi-cli-dbs-add-and-list/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-dbs-add-and-list/config
cat > /tmp/psi-cli-dbs-add-and-list/config/databases.toml <<'TOML'
recent_database_names = []

[[databases]]
name = "smoke-db"
description = "Smoke test database"
path = "/tmp/psi-cli-dbs-add-and-list/smoke-db"
TOML
```

Expected:
- The file exists and contains the entry above.

## Test

### 1. List databases

```bash
psi dbs list
```

Expected:
- Output contains `smoke-db`.
- Output contains `/tmp/psi-cli-dbs-add-and-list/smoke-db`.

## Check

The list output in step 1 is the check.
