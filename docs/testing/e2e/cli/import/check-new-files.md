# CLI Manual Test: Check Files Not Yet Added

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `check` reports files that are not in the database as still to add, and changes nothing.

## Prep

Move into the CLI source directory, clean up any previous test run, create a database and add one file:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.png --db /tmp/psi-test/source --yes
bun run start -- root-hash --db /tmp/psi-test/source
```

Expected:
- The file is added. Note the root hash.

## Test

### 1. Check a file that has not been added

```bash
bun run start -- check ../../test/test.jpg --db /tmp/psi-test/source --yes
```

Expected:
- Output shows `Files to add: 1` and `Already added: 0`.

---

### 2. Check a mix of an added file and a file that has not been added

```bash
bun run start -- check ../../test/test.png ../../test/test.jpg --db /tmp/psi-test/source --yes
```

Expected:
- Output shows `Files considered: 2`, `Files to add: 1` and `Already added: 1`.

## Check

### 3. Confirm check changed nothing

```bash
bun run start -- root-hash --db /tmp/psi-test/source
bun run start -- summary --db /tmp/psi-test/source
```

Expected:
- The root hash is the same as in the prep.
- `Files imported:` is still `1`.
