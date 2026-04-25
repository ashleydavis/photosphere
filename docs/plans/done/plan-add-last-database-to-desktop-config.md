# Add lastDatabase to IDesktopConfig

## Overview
`lastDatabase` is written to and read from the desktop config file, but is not declared as a field on `IDesktopConfig`. This forces two sites in `apps/desktop/src/main.ts` to cast `desktopConfig` to `Record<string, unknown>` in order to set or delete the property. Adding the field eliminates both casts and aligns `lastDatabase` with the other named fields (`lastFolder`, `lastDownloadFolder`, `theme`, `recentSearches`).

## Steps
1. **`packages/node-utils/src/lib/desktop-config.ts` — add field to `IDesktopConfig`**
   Add `lastDatabase?: string;` with a `//` comment after the `lastDownloadFolder` field (line 27).

2. **`apps/desktop/src/main.ts` — remove casts in `notify-database-opened` handler**
   Replace:
   ```ts
   (desktopConfig as Record<string, unknown>).lastDatabase = databasePath;
   ```
   With:
   ```ts
   desktopConfig.lastDatabase = databasePath;
   ```

3. **`apps/desktop/src/main.ts` — remove cast in `notify-database-closed` handler**
   Replace:
   ```ts
   delete (desktopConfig as Record<string, unknown>).lastDatabase;
   ```
   With:
   ```ts
   delete desktopConfig.lastDatabase;
   ```

## Unit Tests
No new unit tests required — this is a pure type fix with no behaviour change.

## Smoke Tests
- Launch the desktop app and open a database; quit and relaunch — the database should auto-open (verifies `lastDatabase` is still written correctly).
- Close the database via menu, quit and relaunch — no database should auto-open (verifies the delete still works).

## Verify
- `bun run compile` from repo root passes with no TypeScript errors.
- `bun run test` passes.

## Notes
- `packages/user-interface/src/main.tsx` reads `lastDatabase` via `config.get<string>('lastDatabase')` — a generic string-keyed API — so no change is needed there.
- The pattern for other fields (`updateLastFolder`, `updateLastDownloadFolder`) uses dedicated helper functions, but the `lastDatabase` write/delete happen inside handlers that already load/save config for other reasons, so extracting helpers would add indirection without benefit.
