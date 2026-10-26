# CLI Miscellaneous Tests

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Manual test scripts for behaviour that does not fit any of the other CLI
test areas.

## Tests

- [config-timestamps.md](config-timestamps.md) - `.db/config.json` tracks `lastModifiedAt` and `lastSyncedAt`
- [mcp-server.md](mcp-server.md) - `psi mcp` server starts and serves tools over stdio
- [info.md](info.md) - `info` on a file on disk and on an asset by ID
- [hash.md](hash.md) - `hash` matches the hash the database records
- [tools.md](tools.md) - `tools` reports the media tools
- [version.md](version.md) - `version` prints the versions
- [news.md](news.md) - `news` shows every news item
- [bug.md](bug.md) - `bug --no-browser` builds a bug report
