# Reset device: remove all databases and secrets

## Overview

There is no way for a user to clear the app's own state. Until recently the smoke tests had one (the `reset-config` test command), but that was scaffolding shipped in the app purely for tests and has been removed. A user who wants to hand a phone on, start again, or clear credentials off a device has no equivalent. This plan adds a real one: a "Reset device" action in Settings that removes every configured database entry, the recent list and every stored secret, behind two confirmations because it cannot be undone. It deliberately does NOT delete database files from disk, only the app's knowledge of them, matching what removing a database entry already does.

## Issues

## Steps

1. **Add the reset logic as a plain function.** Create `packages/user-interface/src/lib/reset-device.ts` exporting `resetDevice`, taking the platform operations it needs (`getDatabases`, `removeDatabaseEntry`, `listSecrets`, `deleteSecret`) via a named options interface rather than the whole platform context, so it is unit-testable without React. It removes every database entry, then every secret, and returns a named result interface reporting how many of each were removed. No new platform-context methods: the four operations already exist on `IPlatformContext`. Must compile and have unit tests passing before this step is complete.

2. **Add the confirmation dialog.** Create `packages/user-interface/src/components/reset-device-dialog.tsx` following the shape of `remove-database-dialog.tsx`. Two steps in the one dialog: the first states exactly what will be removed (counts of databases and secrets, read on open) and that database files on disk are left alone; the second is a distinct final confirmation whose confirm button is the only way through. Cancel and backdrop dismiss return to nothing having happened. Give every control a `data-id` so the smoke tests can drive it. Not unit tested (a React component); covered by the smoke tests below.

3. **Add the entry point to Settings.** In `packages/user-interface/src/pages/configuration.tsx`, add a card at the end of the settings stack with a danger-styled button that opens the dialog. Keep it last, below the existing theme and photo-size cards, so it is not the first thing a thumb lands on. Log a line when the reset completes, so the smoke tests can wait on it.

4. **Add the smoke tests.** Add `apps/smoke-tests/tests/40-reset-device/test.sh` (mobile) and `apps/desktop/smoke-tests/25-reset-device/` (desktop), following the neighbouring tests. Each seeds a database and a secret, drives the reset through the UI, and asserts both lists come back empty. The mobile test seeds its database via `"${PLATFORM}_seed_databases_config"` and adds its secret through the real Add Secret UI, the way the existing tests do.

## Unit Tests

- `packages/user-interface/src/test/lib/reset-device.test.ts` covering `resetDevice`: removes every database entry, removes every secret, reports the counts, and is a no-op that still succeeds when there is nothing to remove.
- No unit tests for the dialog or the settings page: React components, covered by the smoke tests.

## Smoke Tests

- Mobile `40-reset-device`: with one database and one secret present, cancelling at the first step leaves both in place; cancelling at the second step also leaves both in place; confirming both steps empties the database list and the secrets list.
- Desktop `25-reset-device`: the same three cases.

## Verify

- `bun run compile` completes with no errors.
- `bun run test` passes for every package.
- `bun run test:everything` passes (compile, unit, CLI, Electron and the mobile suites).

## Notes

- Scope decision: reset clears the app's configuration (database entries, recents, secrets), not the database files themselves. A local database may be the only copy of somebody's photos, so deleting it is a different and more dangerous feature. The dialog must say this plainly, or a user will assume the photos went too.
- Open question for the user: should there be a separate, clearly-labelled option to also delete the database files on device? Left out here deliberately.
- The four platform operations this needs already exist on `IPlatformContext` and are implemented on desktop and mobile, so no platform-specific code is added and nothing platform-specific goes into `packages/user-interface`.
- Removing entries one at a time means one config write per entry rather than one write for the whole reset. That is the existing behaviour of removing a database entry, and avoids adding a bulk platform method for a rarely-used action.
