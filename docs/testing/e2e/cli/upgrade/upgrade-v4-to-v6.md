# CLI Manual Test: Upgrade v4 Database to v6

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `upgrade` brings a v4 database to the current schema version (6).

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run and copy the v4 fixture to a working directory:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-upgrade-upgrade-v4-to-v6
mkdir -p /tmp/psi-cli-upgrade-upgrade-v4-to-v6
cp -r test/dbs/v4 /tmp/psi-cli-upgrade-upgrade-v4-to-v6/upgrade
```

Expected:
- The fixture is copied to `/tmp/psi-cli-upgrade-upgrade-v4-to-v6/upgrade`.

## Test

### 1. Run upgrade

```bash
psi upgrade --db /tmp/psi-cli-upgrade-upgrade-v4-to-v6/upgrade --yes
```

Expected:
- Output includes `Database upgraded successfully to version 6`.

## Check

### 2. Confirm the database is now version 6

```bash
psi summary --db /tmp/psi-cli-upgrade-upgrade-v4-to-v6/upgrade --yes
```

Expected:
- Output contains `Database version: 6`.

---

### 3. Verify the upgraded database

```bash
psi verify --db /tmp/psi-cli-upgrade-upgrade-v4-to-v6/upgrade --yes
```

Expected:
- Output contains `Database verification passed`.
