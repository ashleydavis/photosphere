# CLI Origin Tests

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Manual test scripts for a database's origin: setting it, and joining a database to a remote with `consolidate`.

## Tests

- [set-origin.md](set-origin.md) - `set-origin` records the origin, and `sync` then needs no `--dest`
- [consolidate-new-remote.md](consolidate-new-remote.md) - `consolidate` creates a remote that does not exist yet
- [consolidate-unrelated-remote.md](consolidate-unrelated-remote.md) - `consolidate` joins an unrelated remote so the two can sync
