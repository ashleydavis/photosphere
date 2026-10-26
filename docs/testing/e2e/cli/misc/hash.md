# CLI Manual Test: Hash

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `hash` prints the same hash for a file that the database records for it.

## Prep

Move into the CLI source directory, clean up any previous test run, create a database and add a file:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.png --db /tmp/psi-test/source --yes
```

Expected:
- The file is added.

## Test

### 1. Hash the file

```bash
bun run start -- hash ../../test/test.png --yes
```

Expected:
- A single hash is printed.

---

### 2. Hash a copy and a different file

```bash
cp ../../test/test.png /tmp/psi-test/copy.png
bun run start -- hash /tmp/psi-test/copy.png --yes
bun run start -- hash ../../test/test.jpg --yes
```

Expected:
- The copy's hash is the same as in step 1. The other file's hash is different.

## Check

### 3. Look the hash up in the database

```bash
bun run start -- info <hash from step 1> --db /tmp/psi-test/source --yes
```

Expected:
- The asset for `test.png` is found by that hash.
