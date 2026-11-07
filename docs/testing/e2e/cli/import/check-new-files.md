# CLI Manual Test: Check Files Not Yet Added

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `check` reports files that are not in the database as still to add, and changes nothing.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create a database and add one file:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-import-check-new-files
psi init --db /tmp/psi-cli-import-check-new-files/source --yes
psi add test/test.png --db /tmp/psi-cli-import-check-new-files/source --yes
psi root-hash --db /tmp/psi-cli-import-check-new-files/source
```

Expected:
- The file is added. Note the root hash.

## Test

### 1. Check a file that has not been added

```bash
psi check test/test.jpg --db /tmp/psi-cli-import-check-new-files/source --yes
```

Expected:
- Output shows `Files to add: 1` and `Already added: 0`.

---

### 2. Check a mix of an added file and a file that has not been added

```bash
psi check test/test.png test/test.jpg --db /tmp/psi-cli-import-check-new-files/source --yes
```

Expected:
- Output shows `Files considered: 2`, `Files to add: 1` and `Already added: 1`.

## Check

### 3. Confirm check changed nothing

```bash
psi root-hash --db /tmp/psi-cli-import-check-new-files/source
psi summary --db /tmp/psi-cli-import-check-new-files/source
```

Expected:
- The root hash is the same as in the prep.
- `Files imported:` is still `1`.
