# CLI Inspect Tests

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Manual test scripts for inspecting and exporting database contents via the
`psi` CLI.

## Tests

- [database-summary.md](database-summary.md) - `summary` output for a populated database
- [export-asset.md](export-asset.md) - Export an asset by ID to a chosen destination
- [export-display-and-thumb.md](export-display-and-thumb.md) - Export the display and thumbnail versions of an asset
- [list-paging.md](list-paging.md) - `list` splits a database larger than the page size into pages
