# Record Deleted Assets by Id and Hash

## Overview

A photo the user deletes must never be imported again, and the database should say so directly rather than the answer falling out of an implementation detail. Today deletion is a `deleted?: boolean` flag on the asset record: the record stays in the database, so its content hash stays in the hash index, so the import's "have we got this already?" lookup finds it and skips the file. That works, and it is not what it looks like: nothing in the import asks about deletion, and nothing says the record has to stay. Any future change that hard-deletes a record, prunes the hash index, or filters deleted assets out of it would silently bring every deleted photo back on the next automatic import, and nothing would fail until a user noticed photos returning.

This makes it explicit: the database keeps a record of what has been deleted, carrying both the asset id and the content hash, and the import consults it. It needs a database format change, which is why it is a plan of its own.

## Issues

## Steps

1. **Decide where the record lives.** Either a collection of its own beside `metadata`, or a section of the database that is loaded with the rest of its state. It has to be readable without loading every asset, because the import consults it per file, and it has to replicate and sync like everything else in the database, because a photo deleted on one device must stay deleted on the others.

2. **Record both the asset id and the content hash on delete.** The id is what the interface already knows and what the merkle tree names; the hash is what the import matches on, because the same photo arriving again from a different device or a different folder is a different file with the same content. Recording only the id would not answer the question the import asks.

3. **Consult it in the import.** `hashFileHandler` in `packages/node-api/src/lib/hash-file.worker.ts` currently answers `filesAlreadyAdded` from `sortIndex("hash", "asc").findByValue(hashHex)` alone. It should answer from that plus the deleted record, and it should say which of the two matched, so the import can tell "already imported" from "deliberately deleted" and report them separately. A user watching an import wants to see those as different outcomes.

4. **Decide what un-deleting means.** If a photo is deleted and the user later wants it back, something has to remove the entry. Restoring an asset in the interface is the obvious trigger. Without this the record is a one-way door, which is the kind of thing that is discovered a year later.

5. **Migrate.** Existing databases have `deleted: true` records and no deleted-assets record. Build the record from them on upgrade, or accept that assets deleted before the upgrade keep relying on their soft-deleted record remaining in the hash index. The second is simpler and the first is safer; the choice depends on whether step 1 makes soft-deleted records removable.

## Unit tests

- The deleted record round-trips through storage, and holds both the id and the hash.
- The import reports a file whose hash is in the deleted record as deleted rather than as already-imported, and the two outcomes are distinguishable.
- A file whose hash is in neither the metadata index nor the deleted record is imported.
- Un-deleting removes the entry, and the same file then imports.
- A database written before this change still behaves correctly, whichever answer step 5 takes.

## Smoke tests

- CLI: import a file, delete the asset, import the same file again, and assert it does not come back. This is the test that would have caught the whole class of problem, and it does not exist today.
- Android and iOS: the same, through automatic import, since that is the path that offers the same photo repeatedly.

## Notes

- What makes this worth doing is not that deletion is broken today. It is that it works by accident. The import never asks about deletion; it asks whether the hash is known, and a soft-deleted record happens to keep the hash known. The behaviour and the mechanism are not connected, so nothing protects the behaviour when the mechanism changes.
- Related, and deliberately not solved here: the automatic import hash cache records the asset id a local file was imported as, so it can skip a file without asking the database. That cache is a performance optimisation the user can clear, so it is not what guarantees a deleted photo stays deleted. This record is. See `plan-import-responsiveness.md` while it exists.
