# CLI Manual Test: v2 Database Is Read-Only

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `summary` and `verify` refuse to load a v2 database and instead
suggest running `psi upgrade`.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run and copy the v2 fixture to a working directory, so that nothing can change the fixture in the repository:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-upgrade-v2-readonly
mkdir -p /tmp/psi-cli-upgrade-v2-readonly
cp -r test/dbs/v2 /tmp/psi-cli-upgrade-v2-readonly/v2
```

Expected: no output.

## Test

### 1. Run `summary` on the v2 copy

```bash
psi summary --db /tmp/psi-cli-upgrade-v2-readonly/v2 --yes
```

Expected:
- The command exits with a non-zero status.
- The error message mentions `upgrade` (suggesting the user run `psi upgrade`).

---

### 2. Run `verify` on the v2 copy

```bash
psi verify --db /tmp/psi-cli-upgrade-v2-readonly/v2 --yes
```

Expected:
- The command exits with a non-zero status.
- The error message mentions `upgrade`.

## Check

The output of steps 1 and 2 is the check.
