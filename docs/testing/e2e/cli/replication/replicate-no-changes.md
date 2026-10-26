# CLI Manual Test: Re-Replicate With No Changes (No-Op)

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a second replication with no intervening changes copies zero files.

## Prep

Move into the CLI source directory, clean up any previous test run, create a database, add a file and replicate it:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source --yes
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes --force
```

Expected:
- Replication completes successfully and copies a non-zero number of files.

## Test

### 1. Run the same replicate command again immediately

```bash
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes --force
```

Expected:
- Output includes `Replication completed successfully`.
- `Total files copied:` reports `0`.

## Check

### 2. Confirm the replica is still consistent with the source

```bash
bun run start -- root-hash --db /tmp/psi-test/source
bun run start -- root-hash --db /tmp/psi-test/replica
```

Expected:
- The two values are identical.
