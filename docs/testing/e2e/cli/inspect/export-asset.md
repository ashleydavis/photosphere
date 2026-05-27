# CLI Manual Test: Export an Asset by ID

Test that `export` writes an asset's original bytes to a chosen destination.

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

### 2. Create a database and add a file

```bash
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source --yes
```

Expected:
- Database created and the file is reported as added.

---

### 3. Read an asset ID from the database

```bash
ls /tmp/psi-test/source/asset
```

Expected:
- One file is listed whose name is a UUID (e.g. `89171cd9-a652-4047-b869-1154bf2c95a1`).

Record that UUID, then substitute it for `<asset-id>` in the next step.

---

### 4. Export the original asset to a file

```bash
mkdir -p /tmp/psi-test/exports
bun run start -- export --db /tmp/psi-test/source <asset-id> /tmp/psi-test/exports/out.jpg --yes
```

Expected:
- Output contains `Successfully exported`.
- The file `/tmp/psi-test/exports/out.jpg` exists.

---

### 5. Confirm exporting a non-existent asset fails

```bash
bun run start -- export --db /tmp/psi-test/source 00000000-0000-0000-0000-000000000000 /tmp/psi-test/exports/missing.jpg --yes
```

Expected:
- The command exits with a non-zero status and reports that the asset cannot be found.
- The file `/tmp/psi-test/exports/missing.jpg` is not created.
