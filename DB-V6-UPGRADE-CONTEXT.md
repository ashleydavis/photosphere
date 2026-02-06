# Database v6 Upgrade — Context and Workflow

**Do not forget: this is the overarching plan for the current work.**

## User's original instructions (first message in this work)

> I want you to upgrade Photosphere to db version 6.
>
> Instructions for implementation are documented here:
> `/home/ash/projects/photosphere/photosphere.wiki/Database-Format-v6-Implementation-Commits.md`
>
> The database spec is documented here:
> `/home/ash/projects/photosphere/photosphere.wiki/Database-Format.md`
>
> As you work through the instructions I need to check and verify each commit before you move forward.

## Reference docs

| Purpose | Path |
|--------|------|
| **Implementation (commit-by-commit)** | `../photosphere.wiki/Database-Format-v6-Implementation-Commits.md` |
| **Database spec** | `../photosphere.wiki/Database-Format.md` |

## Workflow

- Work **one commit at a time** from the implementation doc.
- **Verify each commit** before moving on: `bun run c`, `bun run t`, `./apps/cli/smoke-tests.sh --debug all` (from repo root; smoke tests from `apps/cli/`).
- **Human approval:** After each commit is ready, a human must view the diff, approve it, and commit before starting the next commit.

## Commit progress

- **Commit 1:** Set database version to 6; v6 fixture; smoke tests for conversion — done.
- **Commit 2:** Serialization — move per-file version into serialization library — done.
- **Commit 3:** Serialization — add type code and checksum (v6-only in main API) — done.
- **Commit 4:** Merkle-tree — write/read files tree with type code and checksum (v6-only) — done.
- **Commit 5:** BDB — v6 layout only (collections/, shards/, indexes/) — done.
- **Commit 6:** BDB — add type codes and checksum to all serialized files (v6-only) — done.
- **Commit 7:** API tree — use .db/files.dat for files tree (v6 path only) — done.
- **Commit 8:** CLI init-cmd — version detection (try .db/tree.dat then .db/files.dat) — done.
- Commits 9–16: See implementation doc.

## Backward compatibility and upgrade

- **No backward compatibility** in normal code: the main codebase assumes v6 layout and paths everywhere. Do not branch on version or support old paths in library/API code.
- **Only `psi upgrade`** needs to handle old layouts: it reads from old locations (v5), moves/copies files to new v6 locations, and handles encryption.
- **Encryption in v6:** When the database is encrypted, **all files** in the v6 database must be encrypted, including files that were not encrypted in earlier versions (e.g. `.db/files.dat`, `.db/write.lock`, `.db/config.json`). Upgrade must encrypt those as part of the migration.
