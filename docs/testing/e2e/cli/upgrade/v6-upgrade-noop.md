# CLI Manual Test: Upgrading a v6 Database Is a No-Op

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that running `upgrade` on a v6 database reports that no upgrade is needed
and leaves the database unchanged.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run and copy the v6 fixture to a working directory:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-upgrade-v6-upgrade-noop
mkdir -p /tmp/psi-cli-upgrade-v6-upgrade-noop
cp -r test/dbs/v6 /tmp/psi-cli-upgrade-v6-upgrade-noop/upgrade
```

Expected:
- The fixture is copied to `/tmp/psi-cli-upgrade-v6-upgrade-noop/upgrade`.

## Test

### 1. Run upgrade

```bash
psi upgrade --db /tmp/psi-cli-upgrade-v6-upgrade-noop/upgrade --yes
```

Expected:
- Output includes `Database is already at the latest version (6)`.

## Check

### 2. Confirm version and integrity

```bash
psi summary --db /tmp/psi-cli-upgrade-v6-upgrade-noop/upgrade --yes
psi verify --db /tmp/psi-cli-upgrade-v6-upgrade-noop/upgrade --yes
```

Expected:
- Summary contains `Database version: 6`.
- Verify reports `Database verification passed`.
