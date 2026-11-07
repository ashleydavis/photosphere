# Desktop End-to-End Tests

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Manual test scripts for the Photosphere desktop app.

## Structure

- [import/](import/) - Tests covering file import workflows
- [move/](move/) - Tests covering moving files between databases
- [download/](download/) - Tests covering downloading assets to local folders
- [replication/](replication/) - Tests covering database replication workflows
- [database/](database/) - Tests covering managing database entries in the app
- [secrets/](secrets/) - Tests covering managing secrets in the app vault
- [lan-share/](lan-share/) - Tests covering LAN-share of secrets and database entries
- [news/](news/) - Tests covering the news notifications system
- [mcp/](mcp/) - Tests covering the desktop MCP server
