# CLI Manual Test: Write Commands Fail On v2 Database

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `add` and `remove` refuse to write to a v2 database and instead
suggest running `psi upgrade`.

## Prep

Move into the CLI source directory, clean up any previous test run and copy the v2 fixture to a working directory, so that a write that wrongly succeeds cannot change the fixture in the repository:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test
cp -r ../../test/dbs/v2 /tmp/psi-test/v2
```

Expected: no output.

## Test

### 1. Run `add` against the v2 copy

```bash
bun run start -- add ../../test/test.png --db /tmp/psi-test/v2 --yes
```

Expected:
- The command exits with a non-zero status.
- The error message mentions `upgrade`.

---

### 2. Run `remove` against the v2 copy

The v2 fixture ships a known asset id `27165d3c-207b-46b6-ab4e-bc92a09aeda3`.

```bash
bun run start -- remove 27165d3c-207b-46b6-ab4e-bc92a09aeda3 --db /tmp/psi-test/v2 --yes
```

Expected:
- The command exits with a non-zero status.
- The error message mentions `upgrade`.

## Check

### 3. Confirm the copy was not changed

```bash
diff -r ../../test/dbs/v2 /tmp/psi-test/v2
```

Expected:
- No output.
