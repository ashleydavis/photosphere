# CLI Manual Test: v2 Database Is Read-Only

Test that `summary` and `verify` refuse to load a v2 database and instead
suggest running `psi upgrade`.

## Prerequisites

Navigate to the CLI source directory:

```bash
cd apps/cli/
```

The repo ships a v2 fixture at `test/dbs/v2`.

## Steps

### 1. Run `summary` on the v2 fixture

```bash
bun run start -- summary --db ../../test/dbs/v2 --yes
```

Expected:
- The command exits with a non-zero status.
- The error message mentions `upgrade` (suggesting the user run `psi upgrade`).

---

### 2. Run `verify` on the v2 fixture

```bash
bun run start -- verify --db ../../test/dbs/v2 --yes
```

Expected:
- The command exits with a non-zero status.
- The error message mentions `upgrade`.
