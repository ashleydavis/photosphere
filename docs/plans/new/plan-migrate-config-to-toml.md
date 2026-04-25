# Migrate Configuration Files to TOML

## Overview
Currently Photosphere stores user configuration in JSON files (`databases.json`, `desktop.json`, `.db/config.json`). These are not human-friendly — they lack comment support and are tedious to hand-edit. This plan migrates those files to TOML, which is the standard format for user-facing config in modern tooling (Cargo, Bun, uv, Ruff), supports comments, and maps cleanly to the existing data structures.

## Issues

## Steps

1. **Add TOML dependency** — add `smol-toml` (or `@iarna/toml`) to `packages/node-utils/package.json`
2. **Add `readToml` / `writeToml` helpers** in `packages/node-utils/src/lib/fs.ts` alongside the existing `readJson` / `writeJson` functions
3. **Migrate `databases-config.ts`** — update `packages/api/src/lib/databases-config.ts` to read/write `databases.toml` instead of `databases.json`; update `IDatabasesConfig` field names to use snake_case if appropriate for TOML convention
4. **Migrate `desktop-config.ts`** — update `packages/api/src/lib/desktop-config.ts` to read/write `desktop.toml` instead of `desktop.json`
5. **Migrate `database-config.ts`** — update `packages/api/src/lib/database-config.ts` to read/write `.db/config.toml` instead of `.db/config.json`
6. **Handle migration from old JSON files** — in each `load*Config()` function, if the `.toml` file does not exist but the old `.json` file does, read the JSON and write the TOML, then delete the JSON file
7. **Update config path helpers** — update `getConfigPath()` and any path constants that reference `.json` extensions
8. **Update tests** — update `packages/api/src/test/lib/databases-config.test.ts` and `desktop-config.test.ts` to use TOML fixtures

## Unit Tests

- `readToml()` and `writeToml()` in `node-utils/src/test/lib/fs.test.ts` — round-trip test with a known TOML object
- `loadDatabasesConfig()` — reads a `.toml` file correctly
- `saveDatabasesConfig()` — writes valid TOML
- `loadDatabasesConfig()` migration path — reads old `.json`, writes `.toml`, deletes `.json`
- `loadDesktopConfig()` — reads a `.toml` file correctly
- `saveDesktopConfig()` — writes valid TOML
- `loadDesktopConfig()` migration path — reads old `.json`, writes `.toml`, deletes `.json`
- `loadDatabaseConfig()` — reads `.db/config.toml` correctly
- `saveDatabaseConfig()` / `updateDatabaseConfig()` — writes valid TOML

## Smoke Tests

- Launch the desktop app for the first time after the change — verify `databases.toml` and `desktop.toml` are created in `~/.config/photosphere/`
- Launch the desktop app with existing JSON files present — verify migration runs and TOML files are created, JSON files are removed
- Open a database, change theme, perform a search — verify changes persist to `desktop.toml` and are readable by a text editor
- Add a database via the UI — verify the entry appears correctly in `databases.toml`
- Open a database with `.db/config.toml` — verify replication metadata is preserved

## Verify

- `bun run compile` passes with no TypeScript errors
- `bun run test` passes (all existing tests updated for TOML)
- Manually inspect `~/.config/photosphere/databases.toml` — confirm it is valid TOML with human-readable content
- Run `bun run test:electron` smoke tests pass

## File Format Examples

### `databases.json` → `databases.toml`

**Before (JSON):**
```json
{
  "databases": [
    {
      "name": "Family Photos",
      "description": "Our family photo collection",
      "path": "/home/ash/photos/family"
    },
    {
      "name": "Work Archive",
      "description": "Work-related media",
      "path": "s3:my-bucket:/work",
      "s3Key": "work-s3-credentials",
      "encryptionKey": "work-encryption-key"
    }
  ],
  "recentDatabasePaths": [
    "/home/ash/photos/family",
    "s3:my-bucket:/work"
  ]
}
```

**After (TOML):**
```toml
recent_database_paths = [
  "/home/ash/photos/family",
  "s3:my-bucket:/work",
]

[[databases]]
name = "Family Photos"
description = "Our family photo collection"
path = "/home/ash/photos/family"

[[databases]]
name = "Work Archive"
description = "Work-related media"
path = "s3:my-bucket:/work"
s3_key = "work-s3-credentials"
encryption_key = "work-encryption-key"
```

---

### `desktop.json` → `desktop.toml`

**Before (JSON):**
```json
{
  "lastFolder": "/home/ash/downloads",
  "theme": "dark",
  "recentSearches": ["sunset", "birthday 2024", "beach"],
  "lastDownloadFolder": "/home/ash/downloads",
  "lastDatabase": "/home/ash/photos/family"
}
```

**After (TOML):**
```toml
last_folder = "/home/ash/downloads"
theme = "dark"
recent_searches = ["sunset", "birthday 2024", "beach"]
last_download_folder = "/home/ash/downloads"
last_database = "/home/ash/photos/family"
```

---

### `.db/config.json` → `.db/config.toml`

**Before (JSON):**
```json
{
  "origin": "/mnt/nas/photos",
  "lastReplicatedAt": "2024-03-15T10:30:00Z",
  "lastSyncedAt": "2024-03-15T12:00:00Z",
  "lastModifiedAt": "2024-03-15T14:22:00Z"
}
```

**After (TOML):**
```toml
origin = "/mnt/nas/photos"
last_replicated_at = "2024-03-15T10:30:00Z"
last_synced_at = "2024-03-15T12:00:00Z"
last_modified_at = "2024-03-15T14:22:00Z"
```

---

## Notes

- **TOML chosen over YAML** because YAML has whitespace-sensitivity footguns and security concerns with some parsers; TOML is simpler and safer
- **TOML chosen over JSON5/JSONC** because TOML is a first-class user config format with wide tooling support; JSON5 is niche
- **Snake_case vs camelCase fields**: TOML convention favors `snake_case` for keys; consider renaming fields like `lastDatabase` → `last_database` during migration. This is a breaking change to the file format but backward compatibility is not required
- **`smol-toml`** is the recommended library — it is small, fast, ESM-native, and has no dependencies. Alternative: `@iarna/toml` is more mature but larger
- **`.db/config.toml`** is stored via the storage abstraction (`IStorage`), not direct filesystem — ensure the TOML helpers work through that interface
