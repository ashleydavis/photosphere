# CLI Manual Test: `dbs add` With Duplicate Name Fails

Test that adding a second database with the same name as an existing entry
fails and does not overwrite the original.

## Prerequisites

Navigate to the CLI source directory:

```bash
cd apps/cli/
```

## Steps

### 1. Point the CLI at an empty config directory

```bash
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
```

---

### 2. Add a database the first time

```bash
bun run start -- dbs add --yes --name dup-db --path /tmp/psi-test/dup-db-1
```

Expected:
- The command exits successfully.

---

### 3. Attempt to add a second database with the same name

```bash
bun run start -- dbs add --yes --name dup-db --path /tmp/psi-test/dup-db-2
```

Expected:
- The command exits with a non-zero status.
- The error message contains `already exists`.

---

### 4. Confirm the original entry is intact

```bash
bun run start -- dbs list
```

Expected:
- Output contains `/tmp/psi-test/dup-db-1`.
- Output does not contain `/tmp/psi-test/dup-db-2`.
