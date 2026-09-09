# Show which database is the default on a phone

## Overview

Setting a database as the default is the step that decides where automatic import writes, and on a phone there is no way to tell whether it worked. The **Default** chip that answers the question is rendered only in the desktop table in `packages/user-interface/src/pages/databases/databases-page.tsx`; the mobile card list beneath it renders name, description, path and the actions menu, and nothing else. `Set as default` also writes its setting and logs an event with no toast, so the interface says nothing at the moment it is chosen and nothing afterwards. The only confirmations available on a phone today are indirect: switch automatic import on and see whether a database called **My Photos** appears instead. This puts the same badge on the mobile card that the desktop table already has, so the answer is visible where the choice is made.

## Issues

## Steps

1. **Give `EntityCard` a badge.** In `packages/user-interface/src/components/entity-card.tsx`, add an optional badge to `IEntityCardProps`: the text to show and the `data-id` to show it under. Render it beside the title, as a Joy `Chip` matching the desktop table's (`size="sm"`, `color="primary"`), and render nothing when the prop is absent. `EntityCard` is a React component, so no unit test: step 4 covers it. `bun run compile` must pass before this step is finished.

2. **Mark the entries in one place.** In `databases-page.tsx`, replace the inline `entry.path === defaultDatabasePath` comparison in the desktop table with `markDefaultDatabase` from `packages/user-interface/src/lib/auto-import-config.ts`, which already exists, is already unit tested, and already encodes the rule that exactly one entry is the default. Map the entries once, above the two renderings, and have both read `entry.isDefault`. This is what stops the phone and the desktop deciding it two different ways.

3. **Show the badge on the card.** In the mobile branch of `databases-page.tsx`, pass the badge to `EntityCard` for the entry whose `isDefault` is true, with the **same** `data-id` the desktop table uses, `database-default-badge-<index>`, and the same text `Default`. Keeping the index-based id rather than switching to a name-based one is deliberate: `apps/desktop/smoke-tests/36-consolidate-database/test.sh` asserts the badge moving from index 0 to index 1 and disappearing from 0, so one form of assertion then works on both platforms and no existing test has to change. Leave the `Set as default` action in the menu for the entry that already is the default: the desktop tests click it by `nth`, and removing it for one entry would shift those indices. `bun run compile` must pass before this step is finished.

4. **Cover it with a mobile smoke test.** Extend `apps/smoke-tests/tests/6-add-database-entry/test.sh`, which already registers a database on the Manage Databases page: add a second entry, choose `Set as default` on the first from its card menu, assert `database-default-badge-0` reads `Default`, then choose it on the second and assert the badge has moved to `database-default-badge-1` and that `database-default-badge-0` is gone. Use `wait_for_value` and `wait_for_value_gone`, and the `nth` form of the click command, exactly as the desktop test does. Watch it fail first by asserting the badge on the wrong index.

5. **Update the documentation to match the code**, including the badge's exact text and where it appears. The documents affected are `docs/automatic-photo-backup.md`, `docs/android-onboarding.md` and `docs/testing/e2e/mobile/auto-import/auto-import-existing-remote.md`, all of which tell the reader to set the default without saying how to confirm it.

## Unit Tests

- `markDefaultDatabase` in `packages/user-interface/src/lib/auto-import-config.ts` already has tests in `packages/user-interface/src/test/lib/auto-import-config.test.ts` covering one entry marked, the mark moving, and none marked when there is no default. Step 2 makes the databases page use it rather than duplicating the comparison, so no new logic is introduced and no new unit test is needed. Re-run those tests to prove the reuse did not change what the helper does.
- No unit tests for `EntityCard` or `databases-page.tsx`: React components are covered end to end.

## Smoke Tests

- `apps/smoke-tests/tests/6-add-database-entry`: the **Default** badge appears on the card of the database set as default, moves when a different one is set, and is not on any other card.
- `apps/desktop/smoke-tests/35-auto-import` and `36-consolidate-database` already assert the desktop badge and must keep passing unchanged, which is what proves step 2's refactor did not change the desktop's behaviour.

## Verify

- `bun run compile` passes.
- `bun run test` passes.
- `bun run test:and` passes.
- `bun run test:electron` passes.
- `bun run tev` passes, in one run, as the final check.
- `bun run stories:and` renders the databases page at phone resolution with the badge visible and not overflowing the card at the narrowest width.

## Notes

- **The data already exists on the entry.** `IDatabaseEntry` in `packages/user-interface/src/context/platform-context.tsx` carries `isDefault?`, and `markDefaultDatabase` is what sets it. The mobile card was simply never given anything to render it with, which is why this is a small change rather than new plumbing.
- **The default is read from the config, not the database list.** `databases-page.tsx` loads it with `getDefaultDatabasePath(config)`, which reads `auto_import.default_database_path` from `config.yaml`. That is the same value automatic import reads to decide where to write, so the badge reflects the thing that actually governs the behaviour rather than a second copy of it.
- **Other places the default is invisible** and deliberately out of scope here: the recents list in `left-sidebar.tsx` and the list in `open-database-modal.tsx`. Both show databases and neither marks the default. Worth doing if the human wants it, but the Manage Databases page is where the choice is made and where the question is asked.
- **There is still no confirmation at the moment of choosing.** `makeDefault` in `databases-page.tsx` writes the setting and calls `log.event('Default database set')` with no toast. The badge appearing is the feedback this plan adds; a toast would be a separate decision.
