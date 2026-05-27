# CLI `dbs` Tests

Manual test scripts for the `psi dbs` database-list commands.

## Tests

- [list-empty.md](list-empty.md) - `dbs list` with no entries shows an empty message
- [add-and-list.md](add-and-list.md) - Seeded database entry appears in `dbs list`
- [view.md](view.md) - `dbs view` shows name, path, and secret IDs
- [edit-rename.md](edit-rename.md) - `dbs edit --new-name` renames an entry
- [add-via-flags.md](add-via-flags.md) - `dbs add` via CLI flags
- [add-duplicate-fails.md](add-duplicate-fails.md) - Adding a database with a duplicate name fails
- [remove.md](remove.md) - `dbs remove --yes` removes an entry
- [clear.md](clear.md) - `dbs clear --yes` removes all entries
- [resolve-by-name.md](resolve-by-name.md) - Resolve a database by name through `databases.json`
- [resolve-by-path.md](resolve-by-path.md) - Resolve a database by path through `databases.json`
- [no-match-fallback.md](no-match-fallback.md) - No-match fallback to the existing manual config flow
