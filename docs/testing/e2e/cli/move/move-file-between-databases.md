# CLI Manual Test: Move File Between Databases

> **Warning:** The `psi move` command is not yet implemented.

Test that a file can be imported into one database and moved to another using the CLI.

## Prerequisites

Navigate to the CLI source directory:

```bash
cd apps/cli/
```

## Steps

### 1. Clean up any previous test run

```bash
rm -rf /tmp/psi-test
```

---

### 2. Create a new database

```bash
bun run start -- init --db /tmp/psi-test/source --yes
```

Expected: Output confirms a new media file database was created in `/tmp/psi-test/source`.

---

### 3. Import a file

```bash
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source
```

Expected:
- The file is reported as added.
- No errors are shown.

---

### 4. Create a second database

```bash
bun run start -- init --db /tmp/psi-test/dest --yes
```

Expected: Output confirms a new media file database was created in `/tmp/psi-test/dest`.

---

### 5. Move the file to the destination database

```bash
bun run start -- move ../../test/test.jpg --db /tmp/psi-test/source --dest /tmp/psi-test/dest
```

Expected:
- The file is reported as moved.
- No errors are shown.

---

### 6. Check that the file is no longer in the source database

```bash
bun run start -- list --db /tmp/psi-test/source
```

Expected:
- No files are listed.

---

### 7. Check that the file is now in the destination database

```bash
bun run start -- list --db /tmp/psi-test/dest
```

Expected:
- `test.jpg` is listed.
