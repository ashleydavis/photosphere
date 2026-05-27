# CLI Manual Test: `dbs list` With No Entries

Test that `psi dbs list` shows an empty-state message when no databases are
configured.

## Prerequisites

Navigate to the CLI source directory:

```bash
cd apps/cli/
```

Each `dbs` test isolates the user's databases.json by overriding
`PHOTOSPHERE_CONFIG_DIR`. The smoke-test infrastructure does this with an
auto-cleared temp dir. Use the same approach below.

## Steps

### 1. Point the CLI at an empty config directory

```bash
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
```

Expected:
- `/tmp/psi-test/config` exists and contains no `databases.json` file.

---

### 2. List databases

```bash
bun run start -- dbs list
```

Expected:
- Output includes `No databases`.
