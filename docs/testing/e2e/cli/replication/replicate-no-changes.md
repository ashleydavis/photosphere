# CLI Manual Test: Re-Replicate With No Changes (No-Op)

Test that a second replication with no intervening changes copies zero files.

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

### 2. Create a database, add a file, and replicate it

```bash
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source --yes
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes --force
```

Expected:
- Replication completes successfully and copies a non-zero number of files.

---

### 3. Run the same replicate command again immediately

```bash
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes --force
```

Expected:
- Output includes `Replication completed successfully`.
- `Total files copied:` reports `0`.

---

### 4. Confirm the replica is still consistent with the source

```bash
bun run start -- root-hash --db /tmp/psi-test/source
bun run start -- root-hash --db /tmp/psi-test/replica
```

Expected:
- The two values are identical.
