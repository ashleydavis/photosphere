# CLI Manual Test: Re-Replicate With No Changes (No-Op)

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a second replication with no intervening changes copies zero files.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create a database, add a file and replicate it:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-replication-replicate-no-changes
psi init --db /tmp/psi-cli-replication-replicate-no-changes/source --yes
psi add test/test.jpg --db /tmp/psi-cli-replication-replicate-no-changes/source --yes
psi replicate --db /tmp/psi-cli-replication-replicate-no-changes/source --dest /tmp/psi-cli-replication-replicate-no-changes/replica --yes --force
```

Expected:
- Replication completes successfully and copies a non-zero number of files.

## Test

### 1. Run the same replicate command again immediately

```bash
psi replicate --db /tmp/psi-cli-replication-replicate-no-changes/source --dest /tmp/psi-cli-replication-replicate-no-changes/replica --yes --force
```

Expected:
- Output includes `Replication completed successfully`.
- `Total files copied:` reports `0`.

## Check

### 2. Confirm the replica is still consistent with the source

```bash
psi root-hash --db /tmp/psi-cli-replication-replicate-no-changes/source
psi root-hash --db /tmp/psi-cli-replication-replicate-no-changes/replica
```

Expected:
- The two values are identical.
