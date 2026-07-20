# Review checklist: mobile finish-unfinished-work

Tick each step as you review it. Every step lives in its own git worktree under `.claude/worktrees/<name>`, uncommitted, branched off `mobile`.

To see a step's changes: `git -C .claude/worktrees/<name> status --porcelain` then `git -C .claude/worktrees/<name> diff`. Use `status --porcelain`, not `diff` alone, because most new smoke tests are UNTRACKED and a plain diff will not show them.

`test:and` = the full Android smoke suite on the emulator. It is the gate that proves a mobile gap is actually fixed.

ALL 31 STEPS ARE test:and GREEN AND READY TO REVIEW.

## Ready to review (test:and green)

- [x] 1 - mobile harness fatal by construction - `step-1-mobile-harness-fatal`
- [x] 2 - desktop harness fatal - `step-2-desktop-harness-fatal`
- [x] 3 - state-assertion helpers (`wait_for_value`/`assert_value`) - `step-3-assert-helpers`
- [x] 4 - test driver fails rather than warns - `step-4-test-driver-throws`
- [x] 5 - story player silent passes - `step-5-story-player`
- [x] 6 - real state assertions in the 11 rewritten tests - `step-6-real-assertions`
- [x] 6a+6b - smoke-test numbering + mobile secrets in the device keychain - `step-6ab-numbering-keychain` - smoke test `39-secret-in-keychain`
- [x] 7 (absorbs 8) - LAN receive on mobile - `step-7-lan-receive`
- [x] 9 - `cancelTasks`/`shutdown` honest reporting - `step-9-cancel-shutdown-honest` - smoke test `40-cancel-shutdown-reports-failure`
- [x] 10 - mobile theme survives restart - `step-10-theme-persist` - smoke test `28-theme-persists`
- [ ] 11 - `checkDatabaseExists` real - `step-11-check-db-exists`
- [ ] 12 (absorbs 13) - asset export path - `step-12-export-path`
- [ ] 14 (absorbs 15, 16, 17, 18) - crypto, vault, S3, sync - `step-14-crypto-vault-s3-sync` - smoke tests `32-encrypted-database`, `34-sync` (this worktree runs 29 tests, not 27)
- [ ] 19 - missing task handlers registered + summary entry point - `step-19-task-handlers`
- [ ] 20 - Android timer pump budget - `step-20-timer-pump`
- [ ] 21 - LAN share/receive dialogs surface errors - `step-21-lan-dialog-errors`
- [ ] 22 - dead platform events wired / news deleted - `step-22-platform-events-news`
- [ ] 23 - iOS stops dropping photos that fail to copy - `step-23-ios-photo-copy`
- [ ] 24 - infinite-spinner failure handling - `step-24-infinite-spinner`
- [ ] 25 - `resetConfig` clears the config namespace - `step-25-resetconfig` - smoke test `41-reset-config-clears`
- [ ] 26 - config-store mutators report a miss - `step-26-config-mutators` - smoke test `42-config-mutator-miss`
- [ ] 27 - recent-databases list capped - `step-27-recent-cap` - smoke test `43-recent-databases-cap`
- [ ] 28 - `node-dgram` fails loudly on `udp6` - `step-28-dgram-udp6` - smoke test `44-dgram-udp6-fails-loud`
- [ ] 29 - iOS concurrent `pickFiles` - `step-29-ios-concurrent-pickfiles` - smoke test `45-concurrent-pickfiles`
- [ ] 30 - dead PostCSS config / autoprefixer removed - `step-30-postcss-removed`
- [ ] 31 - ImageMagick quantum depth reconciled (Q16) - `step-31-imagemagick-q16` - smoke test `46-imagemagick-q16`
- [ ] 32 - picked-file extension inference reconciled - `step-32-ext-inference` - smoke test `47-extension-inference`
- [ ] 33 - iOS `test:unit` package script - `step-33-ios-test-unit`
- [ ] 34 - correct every false claim in comments/docs/wiki/READMEs - `step-34-docs-corrections`
- [ ] 35 - bundle id reconciled - `step-35-bundle-id`
- [ ] 36 - mobile versions set to `0.0.1` - `step-36-versions`

## Notes for the reviewer

Steps with no runtime gap have no smoke test, by design: 2, 3, 4, 5 (harness/driver infra), 30 (dead code removal), 33 (iOS script), 34 (docs), 35 (bundle id, exercised implicitly by the suite running under it), 36 (version strings).

Several branches overlap on the same files and will need dedup when merging:
- `mobile-config-store.ts`: steps 25, 26, 27 (27 also contains step 25's `resetConfig` change; the two implementations are convergent).
- iOS `project.pbxproj`: steps 29, 31, 32, 35, 36.
- Shared baseline fixes (the `18/20` `isHovered`/`revealByHover` change, the node-api jest `testTimeout`, the CLI-41 file-logger race) were propagated across many worktrees and will appear repeatedly.

Product bugs found while getting the suite green, worth extra review attention because they would have shipped:
- Step 19: `EnginePool.cancelTasks(source)` permanently poisoned a source, so on mobile the first `TaskQueue.shutdown()` for a database silently killed every later task for it. Fixed on Android and iOS.
- Step 14: the mobile sync scheduler only settled `isSyncRunning` on `sync-completed`, so a skipped or failed sync wedged it forever and no further sync could be enqueued.
- Step 6b: an empty secrets cache could overwrite real secrets (data loss); guarded by a `loadFailed` latch.
- Step 27: mobile `notifyDatabaseOpened` never fired the `onDatabaseOpened` callbacks that desktop fires, so opening a database from the real dialog did not refresh an already-mounted sidebar. Separately, `CollapsibleSection` unmounts its children when collapsed, so a stale collapsed flag can make elements vanish; this also latently threatened tests 18 and 20.
- Step 10: MUI Joy's `initializeValue` reads `localStorage` before falling back to `defaultMode`, so a stale `joy-mode` silently outranks the mode the app restored.
- Step 14: the native host function `secureStoreGet` was unimplemented on both platforms, and on Android a host function must be registered explicitly in `QuickJsTaskEngine` (iOS registers inside `HostBridge.swift`), so adding a bridge method alone is dead code. A new unit test now asserts all 34 host functions are registered on both platforms.

Known flakes, do not treat as regressions: `node-api` `HashCache > should handle buffer resizing for large entries` and the `stampDatabaseStateLocked` test both fail only under parallel load; an intermittent `curl exit 7` teardown blip; an intermittent `sidebar-database-summary` element-not-found in test 35.
