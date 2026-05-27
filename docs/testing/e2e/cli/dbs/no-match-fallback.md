# CLI Manual Test: No-Match Fallback

Test that when `databases.json` has no entry matching the supplied `--db`
argument, the CLI falls back to the existing manual config flow without
errors.

## Prerequisites

Navigate to the CLI source directory:

```bash
cd apps/cli/
```

## Steps

### 1. Point the CLI at empty config and vault directories

```bash
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config /tmp/psi-test/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-test/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
```

---

### 2. Create a plain (unencrypted) database and add a file

```bash
bun run start -- init --db /tmp/psi-test/db --yes
bun run start -- add ../../test/test.png --db /tmp/psi-test/db --yes
```

Expected:
- The database is initialised and the asset is added.

---

### 3. Ensure `databases.json` has no matching entry

```bash
echo '[]' > /tmp/psi-test/config/databases.json
```

---

### 4. Run `summary` against the unregistered database

```bash
bun run start -- summary --db /tmp/psi-test/db --yes
```

Expected:
- The command exits successfully even though `databases.json` does not name this database.
- The summary output reflects the previously-added asset.
