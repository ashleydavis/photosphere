# Desktop Database Tests

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Manual test scripts for managing database entries through the Photosphere
desktop app.

## Tests

- [open-existing-database.md](open-existing-database.md) - Open an existing CLI-created database
- [load-50-asset-fixture.md](load-50-asset-fixture.md) - Load the 50-asset fixture and confirm the gallery renders
- [view-database-details.md](view-database-details.md) - View the details (name, path, secrets) of a database entry
- [edit-database-origin.md](edit-database-origin.md) - Edit a database's origin path and confirm it is persisted
- [remove-recent-database.md](remove-recent-database.md) - Remove a database from the Recent databases list (entry survives)
