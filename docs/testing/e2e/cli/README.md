# CLI End-to-End Tests

Manual test scripts for the `psi` CLI tool.

## Structure

- [import/](import/) - Tests covering file import workflows
- [inspect/](inspect/) - Tests covering inspecting and exporting database contents
- [verify/](verify/) - Tests covering verification and repair
- [remove/](remove/) - Tests covering removing assets from a database
- [compare/](compare/) - Tests covering comparing two databases
- [sync/](sync/) - Tests covering bidirectional sync between two databases
- [move/](move/) - Tests covering moving files between databases
- [replication/](replication/) - Tests covering database replication workflows
- [upgrade/](upgrade/) - Tests covering upgrading older database versions
- [dbs/](dbs/) - Tests covering the `psi dbs` database-list commands
- [vault/](vault/) - Tests covering the `psi secrets` vault commands
- [lan-share/](lan-share/) - Tests covering LAN-share of secrets and database entries
- [misc/](misc/) - Other CLI tests (config timestamps, MCP server)
