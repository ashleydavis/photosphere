# CLI Sync Tests

Manual test scripts for bidirectional sync between databases via the `psi` CLI.

## Tests

- [sync-original-to-copy.md](sync-original-to-copy.md) - Sync propagates a new file from original to copy
- [sync-copy-to-original.md](sync-copy-to-original.md) - Sync propagates a new file from copy back to original
- [sync-edit-field-original.md](sync-edit-field-original.md) - A field edited on the original via `bdb-cli` is synced to the copy
- [sync-edit-field-copy.md](sync-edit-field-copy.md) - A field edited on the copy via `bdb-cli` is synced to the original
- [sync-delete-asset-original.md](sync-delete-asset-original.md) - An asset deleted on the original is removed from the copy
- [sync-delete-asset-copy.md](sync-delete-asset-copy.md) - An asset deleted on the copy is removed from the original
