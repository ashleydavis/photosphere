# CLI Manual Test: Write Commands Fail On v2 Database

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `add` and `remove` refuse to write to a v2 database and instead
suggest running `psi upgrade`.

## Prerequisites

Navigate to the CLI source directory:

```bash
cd apps/cli/
```

## Steps

### 1. Run `add` against the v2 fixture

```bash
bun run start -- add ../../test/test.png --db ../../test/dbs/v2 --yes
```

Expected:
- The command exits with a non-zero status.
- The error message mentions `upgrade`.

---

### 2. Run `remove` against the v2 fixture

The v2 fixture ships a known asset id `27165d3c-207b-46b6-ab4e-bc92a09aeda3`.

```bash
bun run start -- remove 27165d3c-207b-46b6-ab4e-bc92a09aeda3 --db ../../test/dbs/v2 --yes
```

Expected:
- The command exits with a non-zero status.
- The error message mentions `upgrade`.
