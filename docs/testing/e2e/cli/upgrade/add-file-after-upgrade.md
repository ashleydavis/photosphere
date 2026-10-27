# CLI Manual Test: Add a File to a Freshly-Upgraded v6 Database

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a database upgraded from an older format accepts new file imports.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, copy the v6 fixture to a working directory and record its starting file count:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-upgrade-add-file-after-upgrade
mkdir -p /tmp/psi-cli-upgrade-add-file-after-upgrade
cp -r test/dbs/v6 /tmp/psi-cli-upgrade-add-file-after-upgrade/upgrade
psi summary --db /tmp/psi-cli-upgrade-add-file-after-upgrade/upgrade --yes | grep "Total files:"
```

(For deeper coverage, repeat the test against the v2-v5 fixtures by also running
`psi upgrade --db /tmp/psi-cli-upgrade-add-file-after-upgrade/upgrade --yes` after the copy.)

Expected:
- A non-zero `Total files:` value. Record it as the baseline.

## Test

### 1. Add a new file

```bash
psi add test/test.png --db /tmp/psi-cli-upgrade-add-file-after-upgrade/upgrade --yes
```

Expected:
- Output reports the file as added.

## Check

### 2. Confirm the file count increased

```bash
psi summary --db /tmp/psi-cli-upgrade-add-file-after-upgrade/upgrade --yes | grep "Total files:"
```

Expected:
- The new value is the baseline plus 3 (original + display + thumb merkle entries for the one new asset).

---

### 3. Verify the database

```bash
psi verify --db /tmp/psi-cli-upgrade-add-file-after-upgrade/upgrade --yes
```

Expected:
- Output includes `Database verification passed`.
