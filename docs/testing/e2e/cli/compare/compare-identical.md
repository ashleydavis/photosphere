# CLI Manual Test: Compare Two Identical Databases

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `compare` reports no differences for two identical databases.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create a database, add a file and replicate it:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-compare-compare-identical
psi init --db /tmp/psi-cli-compare-compare-identical/source --yes
psi add test/test.jpg --db /tmp/psi-cli-compare-compare-identical/source --yes
psi replicate --db /tmp/psi-cli-compare-compare-identical/source --dest /tmp/psi-cli-compare-compare-identical/replica --yes --force
```

Expected:
- Replica is reported as completed successfully.

## Test

### 1. Compare source and replica

```bash
psi compare --db /tmp/psi-cli-compare-compare-identical/source --dest /tmp/psi-cli-compare-compare-identical/replica --yes
```

Expected:
- Output includes `No differences detected`.

---

### 2. Compare a database with itself

```bash
psi compare --db /tmp/psi-cli-compare-compare-identical/source --dest /tmp/psi-cli-compare-compare-identical/source --yes
```

Expected:
- Output includes `No differences detected`.

## Check

The compare output in steps 1 and 2 is the check.
