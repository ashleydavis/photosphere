# CLI Upgrade Tests

Manual test scripts for upgrading older database versions via the `psi` CLI.

## Tests

- [v2-readonly.md](v2-readonly.md) - `summary` and `verify` reject a v2 database and suggest `upgrade`
- [v2-write-fails.md](v2-write-fails.md) - Write commands (`add`, `remove`) fail on a v2 database
- [upgrade-v2-to-v6.md](upgrade-v2-to-v6.md) - Upgrade a v2 database to v6
- [upgrade-v3-to-v6.md](upgrade-v3-to-v6.md) - Upgrade a v3 database to v6
- [upgrade-v4-to-v6.md](upgrade-v4-to-v6.md) - Upgrade a v4 database to v6
- [upgrade-v5-to-v6.md](upgrade-v5-to-v6.md) - Upgrade a v5 database to v6
- [v6-upgrade-noop.md](v6-upgrade-noop.md) - Upgrading a v6 database is a no-op
- [add-file-after-upgrade.md](add-file-after-upgrade.md) - Add a file to a freshly-upgraded database
