# CLI End-to-End Tests

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

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
- [encryption/](encryption/) - Tests covering encrypting, decrypting, replicating and syncing encrypted databases
- [s3/](s3/) - Tests covering databases stored on S3, against a local MinIO server
- [origin/](origin/) - Tests covering `set-origin` and `consolidate`
- [mcp/](mcp/) - Tests covering the `psi mcp` server
- [info/](info/) - Tests covering the `psi info` command
- [hash/](hash/) - Tests covering the `psi hash` command
- [tools/](tools/) - Tests covering the `psi tools` command
- [version/](version/) - Tests covering the `psi version` command
- [news/](news/) - Tests covering the `psi news` command
- [bug/](bug/) - Tests covering the `psi bug` command
