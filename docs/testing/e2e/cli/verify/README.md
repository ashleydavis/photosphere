# CLI Verify Tests

Manual test scripts for verifying and repairing database integrity via the
`psi` CLI.

## Tests

- [verify-full.md](verify-full.md) - Quick verify versus full verify
- [detect-deleted-file.md](detect-deleted-file.md) - `verify` detects a missing asset file
- [detect-modified-file.md](detect-modified-file.md) - `verify` detects a tampered asset file
- [repair-clean-database.md](repair-clean-database.md) - `repair` is a no-op on a clean database
- [repair-damaged-database.md](repair-damaged-database.md) - Repair a damaged database from a replica
