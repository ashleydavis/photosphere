# Unfinished mobile (Android / iOS) work

Audit date: 2026-07-16. Scope: `packages/mobile-frontend`, `packages/mobile-worker`, `apps/android-frontend`, `apps/ios-frontend`, the native plugin code in both apps, the mobile smoke-test suite, the shared `user-interface` package's behaviour on mobile, and the git/doc record of what was claimed complete.

Purpose: a complete list of what does not work on Android and iOS, ordered by how likely it is to mislead you. Written after a stub that reported success while doing nothing shipped and was found by a user, not by a test.

Not audited: desktop, CLI, web. The same patterns may exist there. Nobody has looked.

## How entries are classified

- **Reports success, does nothing**: the code does nothing (or partial work) while the UI reports success.
- **Plausible value**: returns a plausible value (`[]`, `true`, an echoed input) that is indistinguishable from a real answer, so the failure is invisible.
- **Silent no-op**: does nothing, claims nothing. You see the tap do nothing.
- **Dead event**: a subscription that is registered but never fired, so dependent UI never updates.
- **Fails loudly**: throws or reports NOT IMPLEMENTED. Listed for completeness. These will not surprise you.

The `NOT IMPLEMENTED` machinery in `packages/mobile-worker/src/lib/host-functions.ts` is good and does its job. So is the native layer. The rot is concentrated in two places: `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx` (which has no test file at all) and the shell smoke-test harness.

## 1. Reports success, does nothing

| Fixed | What | Where | What you see |
|:---:|---|---|---|
| [ ] | `importSharePayload` | `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx:349` | Empty body. Receive a database over LAN, review it, tap Save, get a green "Database imported successfully!". Nothing is written. This is the reported bug. The transfer underneath genuinely works, so every other signal says it succeeded. |
| [ ] | Same stub, secrets path | `packages/user-interface/src/components/receive-secret-dialog.tsx:104` | The undiscovered twin of the reported bug. Same empty function, same unconditional `setStep("success")`, `log.event('Secret saved')`. You are told "Secret saved". Nothing was saved. |
| [ ] | `EmbeddedJsQueueBackend.cancelTasks` | `packages/mobile-frontend/src/lib/embedded-js-queue-backend.ts:172` | Bridge rejection swallowed to `console.error`; the `tasksCancelled` callbacks fire unconditionally. Tap Cancel in the Job Manager, the UI clears the jobs, the native engine may keep running the import. Battery drain, files still being written. |
| [ ] | `pickFile` + download toast | `platform-provider-mobile.tsx:307`, toast at `packages/user-interface/src/context/asset-database-source.tsx:479` | `pickFile` echoes its input, so the `if (!destPath) return` cancel guard is dead. Tap Download on a photo: no save dialog, green `Downloaded "IMG_1234.jpg"` toast, file lands in app-private sandbox storage. Not in Photos, not in Files, not reachable. |
| [ ] | Theme persistence | `apps/android-frontend/src/app.tsx:62`, `apps/ios-frontend/src/app.tsx:62` | Mobile hardcodes `"system"` as the saved theme; desktop passes the real one. `theme-toggle.tsx:41` says the choice is "persisted through the app config so it survives restarts". It is written to the real mobile config store and read by nothing. Pick Dark, it applies, it persists to disk, restart, back to System. |

## 2. Plausible value, invisible failure

**The unifying defect: every stub returns exactly the value the shared UI reads as success.** `undefined` means "user cancelled" to every caller, so a truthy return makes cancel impossible and a bogus value silently accepted.

| Fixed | What | Where | What you see |
|:---:|---|---|---|
| [ ] | `pickFolder` returns `"downloads"` | `platform-provider-mobile.tsx:302` | No picker ever appears, and **cancel is impossible**. Six callers, one of which is about downloads: Create Database (`asset-database-source.tsx:362`), batch download (`:499`), Add Database (`add-database-modal.tsx:121`), Create Database modal (`create-database-modal.tsx:121`), Edit Database path (`edit-database-modal.tsx:136`), Replicate destination (`replicate-database-dialog.tsx:150`). Every database you create lands at the literal relative path `"downloads"`, so a second one collides with the first. Editing a database silently rewrites its path to `"downloads"`. |
| [ ] | `checkDatabaseExists` returns `true` | `platform-provider-mobile.tsx:253` | The "Database not found" guard is unreachable on mobile. Tapping a stale recent-database entry closes the database you currently have open and switches to the dead path. You lose the open database and get an empty gallery with no explanation. Hit from `no-database-loaded.tsx:129`, `left-sidebar.tsx:278`, `open-database-modal.tsx:124`, `databases-page.tsx:119`, and the auto-open-last-database path at `main.tsx:274`. |
| [ ] | `listS3Dirs` returns `[]` | `platform-provider-mobile.tsx:345` | S3 browser shows an empty listing with no error, indistinguishable from a correctly authenticated empty bucket. You will go debug your AWS credentials for nothing. |
| [ ] | `setSyncAllowed` is write-only | `platform-provider-mobile.tsx:411`, state at `:15` | `lastSyncAllowed` is written and never read anywhere in the repo. See section 6. |
| [ ] | `EmptyVault.get` returns `undefined` for every key | `packages/mobile-worker/src/shims/vault.ts:34` | Reports "no secret configured" rather than "vault unavailable". Chains into storage: `encryptionKeyPems` ends up empty, so `storage-factory.ts:83` silently skips `EncryptedStorage` and an encrypted database opens as plain storage, reading still-encrypted bytes. Confusing checksum or parse error, never "encrypted databases are not supported on mobile". Read from code, not measured on a device. |
| [ ] | `crypto.getRandomValues` backed by `Math.random()` | `packages/mobile-worker/src/lib/install-globals.ts:249` | Not a CSPRNG. Currently only feeds `uuid` id generation (uniqueness, not secrecy), and the comment admits it. Flagged because it is a global any future crypto consumer silently inherits. |
| [ ] | `os.platform()` / `process.platform` hardcode `"android"` | `packages/mobile-worker/src/shims/node-os.ts:28`, `install-globals.ts:298` | Wrong on iOS. No consumers found in the bundled graph, so latent. |

## 3. Genuine functional bugs (not stubs)

- [ ] **Android LAN-share timeout collapses from 60s to roughly 12s.** `apps/android-frontend/.../QuickJsTaskEngine.java:281` calls `__pumpTimers()` with no argument; iOS passes a real elapsed budget (`JavaScriptCoreTaskEngine.swift:383`). With no budget the virtual clock fires the earliest timer regardless, advancing 250ms per loop iteration rather than per real 250ms. LAN share uses a 60000ms timeout polled every 250ms: 240 pumps at up to 50ms each. Symptom: "couldn't find receiver" on Android long before your other device appears. iOS is correct. Read from code, not measured.
- [ ] **All four LAN share/receive dialogs hang forever on failure.** `use-lan-share-tasks.ts` throws; every catch is log-only, so the UI never leaves its waiting step. `share-database-dialog.tsx:298` (stuck on the pairing code with a spinner), `share-secret-dialog.tsx:176`, `receive-database-dialog.tsx:544` (stuck on "waiting"), `receive-secret-dialog.tsx:214`. No error, no timeout, no way out.
- [ ] **Infinite spinner with zero diagnostics if the asset server fails.** `apps/*/src/app.tsx:77` renders `<FullscreenSpinner />` until `restApiUrl` arrives. `use-asset-server.ts:92` fires the `asset-server` task and subscribes to the ready message with **no awaitTask, no failure listener, no timeout, no retry**. If the task throws, the spinner renders forever. Compounded by `app.tsx:41-49`, where `bootstrapMobileBackend` catches an `init()` failure to `console.error` (invisible on a device) and **installs the backend anyway**, so every later `addTask` dispatches into a dead engine. Desktop throws loudly instead (`apps/desktop-frontend/src/app.tsx:52`).
- [ ] **iOS silently drops photos that fail to copy.** `apps/ios-frontend/ios/App/App/JsEngine/JsEnginePlugin.swift:390` discards the `loadFileRepresentation` error and uses `try?` on the copy. Failed items are omitted from `paths` and the call still resolves successfully. Select 10 photos, 3 fail, 7 import, no error. Android rejects the call properly (`JsEnginePlugin.java:276`).
- [ ] **`resetConfig` does not clear what it claims.** `packages/mobile-frontend/src/lib/mobile-config-store.ts:356` skips the `photosphere.config.*` namespace, so developer mode, theme, `syncEnabled` and `syncOnlyOnWifi` survive. Its comment says "Clears all persisted config". Aimed at the test harness: config leaks across smoke-test runs on a real device, so tests pass or fail based on what a previous run left behind. The test at `mobile-config-store.test.ts:127` only asserts databases are empty, so the gap is uncovered.
- [ ] **`updateDatabase` / `updateSecret` / `setDatabaseOrigin` cannot report a miss.** `mobile-config-store.ts:98`, `:206`, `:128` use `.map()` and return `void`, so a no-such-entry silently rewrites the list unchanged.
- [ ] **`addRecentDatabase` is unbounded.** `mobile-config-store.ts:144`. The recent list grows forever, no cap or trim.
- [ ] **Concurrent `pickFiles` drops the first call.** `JsEnginePlugin.swift:144` overwrites `pendingPickCall` without resolving it, leaving the first JS promise unsettled forever. Mitigated because the picker is modal.
- [ ] **`postcss.config.js` is dead config, autoprefixer never runs.** Both apps ship `.postcssrc` (tailwind only) and `postcss.config.js` (tailwind + autoprefixer). `postcss-load-config` searches `.postcssrc` first, so autoprefixer never executes despite being a declared devDependency. Verified against the built CSS. No vendor prefixing on the platform that needs it most. Secondary hazard: `package.json` sets `"type": "module"` but `postcss.config.js` uses CJS `module.exports`, so deleting `.postcssrc` to "clean up" makes the survivor throw. Repo-wide pattern, not mobile-specific.

## 4. Silent no-op

All in `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx` unless noted.

- [ ] `openDatabase` (`:73`). Tap to open a database: no dialog, no event, no error. Currently not wired to any UI, so latent.
- [ ] `copyToClipboard` (`:178`). Tap copy on a photo: nothing, no toast either way. Paste gives you whatever was on the clipboard before. Button rendered unconditionally at `asset-view.tsx:326`.
- [ ] `openFolder` (`:234`). The "Open Folder" button on download toasts does nothing. Compounds `pickFolder`: the hardcoded `"downloads"` is truthy, so the button gets attached at all (`asset-database-source.tsx:527`, `:542`, `main.tsx:150`).
- [ ] `notifyDatabaseEdited` (`:175`). Desktop uses this to schedule a debounced sync. On mobile every edit (label, star, delete, metadata) is silently never queued for sync.
- [ ] `notifyDatabaseClosed` (`:97`). Low impact today. The open half is fully implemented, so this is an asymmetry that bites when mobile grows a scheduler.
- [ ] `prefetch-database` never registered (`packages/mobile-worker/mobile-worker-entry.ts`). `load-assets.worker.ts:94` fire-and-forget queues it for partial databases and never awaits, so the failure surfaces nowhere. Opening a partial database on mobile silently skips thumbnail prefetch, permanently, with no indication. **The only genuinely silent task gap.**
- [ ] `EmbeddedJsQueueBackend.shutdown` (`embedded-js-queue-backend.ts:212`). Native teardown failure invisible, engine pool may leak.
- [ ] `Transform` / `Duplex` / `PassThrough` / `Stream` (`packages/mobile-worker/src/shims/node-stream.ts:220`). No-op constructors, inheritance bases only. Piping real data through one would vanish silently.
- [ ] `dgram.createSocket` ignores its type argument (`node-dgram.ts:302`), so `udp6` silently becomes udp4. `setBroadcast` (`:232`) is a no-op but benign.

## 5. Dead event (registered, never fires)

All in `platform-provider-mobile.tsx`.

| Fixed | Method | Line | Consequence |
|:---:|---|---|---|
| [ ] | `onDatabasesChanged` | 226 | After a replication registers a new database, the Manage Databases list does not refresh until manual reload. |
| [ ] | `onSyncStarted` / `onSyncCompleted` | 182 / 186 | `isSyncing` permanently false. The navbar sync indicator (`navbar.tsx:129`) can never appear. |
| [ ] | `onDatabaseClosed` | 84 | No external close path. |
| [ ] | `onDatabaseOpened` | 77 | `notifyDatabaseOpened` records the recent entry but never invokes the callbacks. The database still loads (set directly), so recents and the database list just do not refresh. Degradation, not breakage. |
| [ ] | `onThemeChanged` | 100 | OS-level light/dark switch does not propagate. The in-app toggle works (set directly via `setMode`). The real theme bug is persistence, section 1. |
| [ ] | `onNavigate` | 171 | Makes `/database-summary` unreachable, section 7. Otherwise benign, no menu on mobile. |
| [ ] | `onUpdateAvailable` | 230 | Benign. Store updates are the intended mobile path. Makes `markUpdateAsShown` (`:352`, also empty) unreachable dead code. |

**Two that are production-dead but test-alive.** These look fully implemented (real `Set`, real add/delete, real unsubscribe) and their tests pass:

- [ ] `onPlatformEvent` (`:104`) fires only from `TEST_MENU_EVENT` at `:117`. Drives the whole menu-action switch. For modal-opening actions the tests land on the same state the real sidebar reaches, so those tests bypass the door but exercise the real room.
- [ ] `onDatabaseOpened` (`:77`) fires only from `TEST_OPEN_DATABASE_EVENT` at `:121`. Its only production dispatcher is the Electron main process. **No mobile user can trigger this channel**, yet four smoke tests drive the app through it.

## 6. Settings that control nothing

- [ ] **Sync toggles.** `configuration-dialog.tsx:88` ("Enable syncing") and `:99` ("Only sync over Wi-Fi") → `sync-context.tsx:133` → `setSyncAllowed` → writes `lastSyncAllowed`, read by nothing. Reachable on mobile via the navbar/sidebar config button. The toggles flip, persist, log `log.event('Syncing enabled')`, and do nothing. There is no mobile sync scheduler and no `sync-database` handler, so they gate a sync that cannot run. On a metered plan you would trust "Only sync on Wi-Fi" and it has no addressee.
- [ ] **S3 and encryption offered in the pickers.** `add-database-modal.tsx:244` and `create-database-modal.tsx:251` offer `<Option value="s3">S3</Option>` plus "Browse S3". `secrets-page.tsx:36` offers `s3-credentials` and `encryption-key`. These store fine in localStorage, so you can create S3 credentials and encryption keys and then find every consumer of them inert. Encryption keys attached at `add-database-modal.tsx:167` are accepted and persisted with no mobile crypto behind them.

## 7. Missing background task handlers

`mobile-worker-entry.ts:34-66` registers 13. `packages/node-api/src/lib/task-handlers.ts` registers 18. Missing on mobile:

| Fixed | Task | Verdict |
|:---:|---|---|
| [ ] | `get-database-summary` | Route mounted on mobile, **fails loudly** with a raw handler-registry error naming internal task types. Also effectively unreachable: the only entry point is a native desktop menu item delivered through `onNavigate`, a no-op on mobile. Dead route, zero smoke-test coverage. |
| [ ] | `prefetch-database` | **Silent no-op.** See section 4. |
| [ ] | `sync-database` | No mobile scheduler exists. See section 6. |
| [ ] | `verify-file`, `check-file` | CLI only, not reachable from mobile UI. Fine. |

## 8. iOS vs Android divergence

- [ ] **ImageMagick quantum depth differs.** iOS builds Q8 HDRI from source (`apps/ios-frontend/ios/build-imagemagick.sh:82`); Android uses prebuilt Q16 HDRI (`apps/android-frontend/android/app/src/main/cpp/CMakeLists.txt:42`). iOS thumbnails are 8-bit per channel: subtle banding versus Android, and byte-different output for identical source, so any cross-platform image hash comparison diverges. Undocumented.
- [ ] **Picked-file extension inference differs.** Android falls back to the mime subtype (`ImportPicker.java:40`); iOS has no mime fallback (`ImportPicker.swift:29`). An extension-less item becomes `.bin` on iOS where Android infers `.jpeg`.
- [ ] **Only Android has a `test:unit` package script.** `bun run --filter=ios-frontend test:unit` silently does nothing (bun no-ops on a missing script under `--filter`); Android's runs. A future `bun --filter '*' test:unit` would run Android's tests and skip iOS's without saying so.
- [ ] **Timer pump budget** and **picked-file error handling**: see section 3.

## 9. Ship blockers

- [ ] **Bundle id is a self-admitted placeholder and disagrees with desktop.** `apps/*/capacitor.config.ts:5` says "placeholder; reconcile with the desktop bundle id before any store build" and sets `au.com.codecapers.photosphere`. `apps/desktop/package.json:61` sets `com.codecapers.photosphere`, no `au.` prefix. The reconciliation never happened, and the value has propagated into four generated native locations. Android `applicationId` is permanent after first Play upload: reconciling later needs a new listing and orphans every installed user.
- [ ] **App icon is the stock Capacitor logo** on both platforms. Rendered and confirmed: the Capacitor blue-X mark on graph paper, dated Aug 2024 (scaffold date), never replaced. Guaranteed store rejection.
- [ ] **Splash screen is also the stock Capacitor logo.** Every cold start flashes it.
- [ ] **Mobile claims v1.0 for a v0.0.1 product.** `build.gradle:10` (`versionCode 1`, `versionName "1.0"`) and the iOS `MARKETING_VERSION = 1.0` are untouched Capacitor defaults. Nothing derives the mobile version from the root version and nothing bumps `versionCode`, so the second upload is rejected.
- [ ] **Neither platform builds from a fresh clone.** Android `jniLibs/*.so` and `cpp/imagemagick/` are git-ignored and need `scripts/fetch-mobile-media-tools.sh`. iOS `vendor/im` is git-ignored and needs `ios/build-imagemagick.sh` (macOS only). `OTHER_LDFLAGS` hard-codes `-lMagickWand-7.Q8HDRI`, so a fresh iOS clone fails at link.
- [ ] **Both app READMEs document `bun run launch`.** No such script exists anywhere in the repo. The real one is `run`, or `bun run run:and` / `run:ios` from root.

## 10. The mobile test suite is not evidence

This is why the bug reached a user. **No mobile test could have caught it.** Not "was missed": the code path is unreachable from every mobile test and every story.

- **`check_no_errors` cannot fail the test in 17 of 25 tests.** No `test.sh` sets `-e` and neither does `lib/common.sh`. `run.sh:47` invokes `bash "$test_path"`, a fresh shell, so `run.sh`'s own `set -euo pipefail` does not propagate. `check_no_errors` (`lib/common.sh:308`) signals failure by `return 1`, and where it is called unguarded that return is discarded. The harness then prints **PASS**. Proven empirically: it prints `[FAIL] Errors found in app.log` and reports PASS. Only 7 tests guard it with `|| exit 1`.
- **Success log lines were added to mobile so the tests would see them.** Four sites carry the comment "so smoke tests observe the same log line" (`platform-provider-mobile.tsx:282`, `:342`, `:358`, `:94`). Each is a `log.info` sitting next to the work rather than proving it. Delete the work, keep the line, test passes.
- **Tests that pass against an empty stub.** `11`/`12`/`13`/`14`-edit-* assert `"Secret updated"`, emitted by the UI after the await. Stub `updateSecret` and all four pass. `13` types `eu-west-1` and `14` types `new-name`; neither ever reads the value back. `11`'s header comment claims it "asserts the raw PEM round-trips". There is no such assertion in the file. Same shape for `22-edit-database-origin`, `5-add-secret`, `17-replicate-database` (never checks the replica), `9-view-secret` and `10-view-database` (never read the revealed value, so `getSecretValue` returning `undefined` passes both).
- **`0-launch-and-navigate` asserts nothing about the app.** It waits for a string the test driver itself emits (`test-driver.ts:311`) *before* the navigation is assigned on `:312`. It proves a curl reached the driver. The screenshot is never checked for existence or size.
- **`17-news-notifications` is fiction.** `seedNews` is called from exactly one production-file site: inside the `TEST_SEED_NEWS_EVENT` handler. Nothing on mobile fetches news. The test seeds, observes, dismisses, and passes, validating a feature with no production entry point whatsoever.
- **`9-share-roundtrip` tests the transport, not the feature.** It calls `runLanShareRoundtrip`, a function that exists **only in `test-driver.ts:35-72`**. It pushes tasks straight onto a `TaskQueue` and reads the payload directly. It never mounts the receive dialog, never calls the app context, never touches the platform provider. So a green "share works end-to-end" test sat next to a dialog telling users "Database imported successfully!" after calling an empty function.
- **Stories structurally cannot detect it.** `receive-database-dialog.stories.tsx:14` renders the dialog in its initial code-entry state and never clicks import, and the story mock's `importSharePayload` is *itself* `async () => {}` (`stories/mocks/index.tsx:226`). A story "passes" unless it throws a render error. `story-player.sh:268` swallows both curls with `|| true`, and `screenshot_count` is reported but never asserted `> 0`, so a run with zero screenshots exits 0. CI states these jobs are deliberately not in the release gate.
- **`story-player.sh:508` passes a third arg to `wait_for_log`, which takes two.** The "generous timeout" of 900 is silently ignored; the real limit is 120.
- **Zero unit coverage of the provider.** `platform-provider-mobile.tsx` is imported by nothing except the barrel. No test file touches it. `packages/mobile-frontend/package.json:11` uses `jest --passWithNoTests`, currently harmless (4 test files exist) but a renamed directory would report green silently.

**Worth keeping:** `1-load-fixture` (asserts real JPEG bytes off the asset server, but is conditionally skipped on iOS), `9-share-roundtrip` scoped to transport, `4-import-photos` / `21-import-video` (a stubbed import would fail the gallery count). `packages/mobile-worker` (26 test files) and the native suites are substantive and CI-gated. The rot is the provider layer and the shell harness, not below it.

## 11. What was claimed, and when

- **`a5a02308` (2026-06-27) "Implemented background tasks on mobile devices."** The only substantive mobile commit with **no body at all**, and every one of these stubs traces to it. Verified with `git log -S`: the empty `importSharePayload` landed here, `listS3Dirs` returning `[]` landed here, and `checkDatabaseExists` was **changed from returning `false` to returning `true`** here. A stub that failed loudly was replaced with one that returns a plausible value, under the word "Implemented".
- **`2ac1e73b` (2026-07-06) "Fixed iOS build and completed mobile media, import, and LAN-share".** FALSE on LAN-share, in the subject line where it gets read. Media and import are true. The transport was completed; the receive path was empty then and is empty now. The cited proof is "all 25 iOS smoke tests pass", which per section 10 is structurally incapable of seeing this.
- **`12e07639` (2026-07-04) "Made LAN sharing work on Android over native primitives"**, body claims the transfer is "verified end to end". Partially true: it is end to end up to the task queue. The smoke test enqueues raw `receive-share` tasks, a design choice recorded in the plan to avoid driving two UI dialogs. The test path deliberately routes around the only broken part.
- **`4eaa7407` (2026-06-29)** states plainly that success log lines "are now emitted on the mobile path so the ported smoke tests observe them". This is the mechanism behind section 10.
- **`44a27a5c` (2026-07-04)**, the sync toggles, is scrupulous in the body: the gate is computed "without yet being consumed because mobile has no background sync scheduler". It shipped the toggles into the mobile Settings UI anyway. An accurate commit message is not a fence.
- **The wiki is the largest volume of flatly false material, and it is false about the thing that is most absent: sync.** `photosphere.wiki/How-It-Works.md` fences some mobile claims with "Note: this is planned." (`:49`, `:208`). These five are unfenced and read as shipped fact: `:193` "Mobile app: imports new photos and videos as they are taken or saved to the device, running automatically in the background" (no background import exists); `:275` table row "Sync | Not available | Automatic (desktop and mobile apps)"; `:280` "the desktop and mobile apps resume syncing automatically. No user action is needed"; `:311` "The desktop and mobile apps sync automatically in the background"; `:425` "the desktop and mobile apps perform reverse geocoding automatically in the background". All false. `:556`, `:579`, `:602` describe deployments where mobile devices sync via S3, which is unavailable on mobile entirely.
- **Accurate, for contrast:** `README.md:19` says mobile is "COMING SOON", and `d667c10f` (2026-06-25) explicitly recorded "checkDatabaseExists returns **false**... Real import, sync, vault, and share functionality is intentionally not yet wired up". That was the truth, two days before it was flipped to `true` under "Implemented".

## 12. Comments that are factually wrong

These matter because they misdirect the next reader.

- [ ] **`platform-provider-mobile.tsx:53-58`**, wrong on three counts: claims the vault is stubbed (all five secret methods are real), claims the file-picker is stubbed (`pickFiles` reaches the real native picker), and claims share/receive "fail at runtime until native networking host functions exist". That last one was already false when written: the comment landed in `e6bba24e` (2026-07-03), `TcpHost.java` landed in `f882562b` (2026-06-30). **This comment is what let the `importSharePayload` bug hide.** A reader who trusts it concludes share is broken upstream and never looks at the empty function.
- [ ] **`use-lan-share-tasks.ts:55-57`**: same false claim, that the handlers are absent. They are registered at `mobile-worker-entry.ts:64-66`.
- [ ] **`CLAUDE.md:57`** and **`docs/background-tasks.md:17`**: "Node.js APIs are not implemented for the engine". Stale. All 30 host functions are implemented on both platforms. It understates, which is the safe direction, but it points at the wrong gaps so a reader looking for what is broken looks in the wrong place.
- [ ] **`apps/*/src/app.tsx:52-53`**: "the UI renders immediately". It does not: the `restApiUrl` gate that renders a spinner instead was added after this comment. "backed by the stubbed mobile platform provider" is also stale.
- [ ] **`apps/*/src/app.tsx:38-39`**: a failed init "does not block the UI". Post-gate it blocks the UI permanently, the precise opposite.
- [ ] **`theme-toggle.tsx:41-42`**: the theme is "persisted through the app config so it survives restarts". Not on mobile. This comment is what makes the theme bug actively misleading rather than a silent no-op.
- [ ] **`env-theme.ts:10-11`**: "the app starts from the saved theme". True on desktop, false on mobile.
- [ ] **`node-fs-promises.ts:5-8`**: claims `writeFile`/`mkdir`/`rename`/`unlink`/`rm` throw. They are implemented at `:217-255`.
- [ ] **`mobile-config-store.ts:23-26`**: "secret accessors land with the secrets feature". They landed, at `:185-235`.
- [ ] **`mobile-config-store.ts:352`**: "Clears all persisted config". It does not.
- [ ] **`CMakeLists.txt:31`**: says the ImageMagick libs are "committed under jniLibs/<abi>". They are git-ignored, contradicting lines 8-9 of the same file.
- [ ] **`ImportPicker.java:37-39`**: claims `jpg` is mapped to `jpeg`. No such mapping exists. No test covers the claim.
- [ ] **`capacitor.config.ts:14`**: "No Capacitor plugins configured yet." `@capacitor/network` is installed and synced, and there is a custom `JsEngine` plugin.
- [ ] **`build.gradle:89-90`**: names `bun run test:android:unit`. The script is `test:and:unit`.
- [ ] **`platform-provider-mobile.tsx:13-14` and `:407-409`**: "retained for a future mobile scheduler to read" states an intent as a fact. Nothing reads it.
- [ ] **`asset-database-source.tsx:329-331`**: says `platform.openDatabase` will show a dialog and send a `database-opened` event. On mobile it does neither.
- [ ] **`JavaScriptCoreTaskEngine.swift:163` and `QuickJsTaskEngine.java:388`**: both claim the bundle does not install `setInterval`. It does. Behaviour is correct, the comments are not. Flagged to pre-empt a false alarm.
- [ ] **`11-edit-encryption-key` header**: claims it "asserts the raw PEM round-trips". It does not.

## 13. Gaps that fail loudly (listed for completeness)

These will not surprise you.

- [ ] **Encrypted databases**: `node-crypto.ts:151-231`. `createPrivateKey`, `createPublicKey`, `createCipheriv`, `createDecipheriv`, `privateDecrypt`, `publicEncrypt`, `randomBytes` all throw. Caveat: see `EmptyVault` in section 2. When no key is found the encrypted path is skipped silently before these are ever called, so the silent path is the live one.
- [ ] **S3**: `packages/mobile-worker/src/shims/aws-s3.ts:14`, `aws-lib-storage.ts:17`.
- [ ] **child_process**: `node-child_process.ts:29-50`, all four throw.
- [ ] **Outbound networking**: `node-net.ts` has no `connect`/`createConnection`; `node-http.ts` has no `request`/`get`. Server only. Missing methods give a plain `TypeError`.
- [ ] **`node-fs`**: only `createReadStream` / `createWriteStream`.
- [ ] **iOS 13 import**: `JsEnginePlugin.swift:140`. Deployment target is 13.0 but `pickFiles` rejects below iOS 14 (PHPicker requirement). On iOS 13 the app runs but importing always fails with a clear message. Android's floor is minSdk 24 with no such gap.
- [ ] **Media tools not linked**: exit code -1 with a visible "ImageMagick not linked" message. Both flags are wired in the real builds, so this is a fallback, not the normal path. Note iOS has two independent gates (the Swift `IMAGEMAGICK_LINKED` flag and `__has_include` in C) which can disagree.
- [ ] **`sha256` host function**: `HostFunctions.java:82`, `HostBridge.swift:547`. Plain stub on both, zero callers. Dead code.

## 14. Scaling risk

Whole-file memory model. `node-fs.ts:16-23` reads entire files as base64; `node-http.ts:498-517` buffers the entire response before one write; the bridge adds roughly 1.33x for base64 plus JS string overhead. Importing or serving a large video could plausibly OOM on a low-end device. No backpressure anywhere: `node-stream.ts:153`, `node-net.ts:186`, `node-http.ts:479` all unconditionally `return true`.

## The pattern

One stub in this audit is fenced correctly: `getPathForFile` (`platform-provider-mobile.tsx:237`) returns `undefined` but is paired with `supportsDragAndDropImport: false` at `:433`, which `import-page.tsx:285` actually checks to hide the drop zone. The stub is unreachable because the UI knows it is unimplemented.

It is the **only** capability flag in the entire platform context. There is no flag for clipboard, folder picking, file picking, open-folder, S3 listing, database-existence checking, LAN share/receive, sync scheduling, `notifyDatabaseEdited`, or `openDatabase`. `useIsMobile()` is not a substitute: it is a viewport media query whose own docstring says "This reflects form factor only; it does not indicate the native platform", and not one of its ~100 usages fences a capability. They all adjust padding and font sizes.

So the stubs were written to be maximally polite, and every value they return (`"downloads"`, `true`, `[]`, `defaultFilename`, a silent resolve) is exactly the value the shared UI reads as success. The mobile layer fails in the vocabulary the UI trusts most. That is why mobile looks like it works: no exception is thrown, no error path is taken, and in two dialogs the UI congratulates the user on work that never happened.

Adding a capability flag per unimplemented area, checked by the caller, would convert most of section 1, 2, 4 and 5 into gaps that fail loudly without implementing a single native feature. That is the cheap fix and it is separate from building the features.
