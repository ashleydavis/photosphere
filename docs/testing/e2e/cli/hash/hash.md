# CLI Manual Test: Hash

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `hash` prints the same hash for a file that the database records for it.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, point the CLI at an empty config directory, create a database and add a file:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-hash-hash
mkdir -p /tmp/psi-cli-hash-hash/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-hash-hash/config
psi init --db /tmp/psi-cli-hash-hash/source --yes
psi add test/test.png --db /tmp/psi-cli-hash-hash/source --yes
```

Expected:
- The file is added.

## Test

### 1. Hash the file

```bash
psi hash test/test.png --yes
```

Expected:
- A single hash is printed.

---

### 2. Hash a copy and a different file

```bash
cp test/test.png /tmp/psi-cli-hash-hash/copy.png
psi hash /tmp/psi-cli-hash-hash/copy.png --yes
psi hash test/test.jpg --yes
```

Expected:
- The copy's hash is the same as in step 1. The other file's hash is different.

## Check

### 3. Look the hash up in the database

```bash
psi info <hash from step 1> --db /tmp/psi-cli-hash-hash/source --yes
```

Expected:
- The asset for `test.png` is found by that hash.
