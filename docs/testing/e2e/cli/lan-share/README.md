# CLI LAN-Share Tests

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Manual test scripts for sharing secrets and database entries between two CLI
instances over the local network.

## Tests

- [share-secret.md](share-secret.md) - Share a secret from one CLI to another over LAN
- [share-database.md](share-database.md) - Share a database entry (with its linked secrets) over LAN
