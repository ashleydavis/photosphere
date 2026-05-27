# CLI Manual Test: `dbs add` via CLI Flags

Test that `dbs add` can register a database non-interactively using `--name`
and `--path`.

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

### 2. Add a database entry via CLI flags

```bash
bun run start -- dbs add --yes --name cli-db --path /tmp/psi-test/cli-db-path
```

Expected:
- The command exits successfully.

---

### 3. Confirm the new entry is listed

```bash
bun run start -- dbs list
```

Expected:
- Output contains `cli-db`.
- Output contains `/tmp/psi-test/cli-db-path`.
