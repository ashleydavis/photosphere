# CLI Manual Test: Add a File to a Freshly-Upgraded v6 Database

Test that a database upgraded from an older format accepts new file imports.

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

### 2. Copy the v6 fixture to a working directory

```bash
cp -r ../../test/dbs/v6 /tmp/psi-test/upgrade
```

(For deeper coverage, repeat the test against the v2-v5 fixtures by also running
`bun run start -- upgrade --db /tmp/psi-test/upgrade --yes` between steps 2
and 3.)

---

### 3. Record the starting asset count

```bash
bun run start -- summary --db /tmp/psi-test/upgrade --yes | grep "Total files:"
```

Expected:
- A non-zero starting value. Record it as the baseline.

---

### 4. Add a new file

```bash
bun run start -- add ../../test/test.png --db /tmp/psi-test/upgrade --yes
```

Expected:
- Output reports the file as added.

---

### 5. Confirm the asset count increased

```bash
bun run start -- summary --db /tmp/psi-test/upgrade --yes | grep "Total files:"
```

Expected:
- The new value is the baseline plus 3 (original + display + thumb merkle entries for the one new asset).

---

### 6. Verify the database

```bash
bun run start -- verify --db /tmp/psi-test/upgrade --yes
```

Expected:
- Output includes `Database verification passed`.
