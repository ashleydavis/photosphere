# CLI Replication Tests

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Manual test scripts for database replication via the `psi` CLI.

## Tests

- [replicate-full-copy.md](replicate-full-copy.md) - Create a database, import a file, verify it, replicate a full copy, and verify the replica
- [replicate-partial-copy.md](replicate-partial-copy.md) - Create a database, import a file, verify it, replicate a partial copy, and verify the replica
- [replicate-deleted-asset.md](replicate-deleted-asset.md) - Replicate a database that has had an asset removed
- [replicate-unrelated-fails.md](replicate-unrelated-fails.md) - Replication between two unrelated databases fails
- [replicate-no-changes.md](replicate-no-changes.md) - Re-replicating without changes is a no-op
- [replicate-incremental-changes.md](replicate-incremental-changes.md) - Replicate after adding new files copies just the new files
