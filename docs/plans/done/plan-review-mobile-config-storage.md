# One Config Store For All Three Platforms

## Overview

This plan replaced an earlier one that audited how mobile stored configuration. Almost every defect that plan described has since been fixed by other work: the configured-databases list, the recents and the last-opened database moved out of WebView `localStorage` into `databases.toml` in the storage sandbox on the same shared format desktop uses, with the recents cap and the lost-update lock that go with it, and the per-feature settings files merged into one `config.yaml` that mobile already reaches through the embedded worker's `read-config` / `write-config` tasks. The audit the old plan asked for would have described a world that no longer exists, so what is left is the part it named as the real goal: make the three platforms work the same way wherever there is no reason for them to differ, one file format, one set of operations, one place the format is defined.

Three things stand in the way of that, all found by reading the current code.

The shared interface works in one flat namespace of string keys (`IConfig` in `packages/user-interface/src/context/config-context.tsx`). On desktop, `set-config` (`apps/desktop/src/main.ts`) writes whatever key it is given into `IAppConfig` and `updateAppConfig` then serialises it with `appConfigToYaml`, which writes only the fields it declares. Every other key is silently dropped. That is not hypothetical: `savedSearches` and the collapsed state of every `CollapsibleSection` are written by the shared interface and never survive a restart on desktop, while they do on mobile, because `localStorage` accepts any key. A setting that appears to save and does not is exactly the quiet wrong answer this repository refuses.

Mobile keeps the rest of that flat namespace in `localStorage` while its automatic-import and syncing keys go to `config.yaml`. Local storage belongs to the WebView, so nothing else can read it, the operating system can clear it, and the split means the same setting lives in a different place depending on which key it is.

The news state is split the same way: desktop and the CLI record shown news ids and the last announced release in `config.yaml`'s `news` section through `packages/node-api/src/lib/news-state.ts`, mobile records the ids in `localStorage`, and mobile's `markUpdateAsShown` is an empty function that reports success and does nothing.

The fix is one flat key store, defined once, backed by `config.yaml` everywhere.

## Issues

<!-- Populated later by plan:check -->

## Steps

1. **Give the document a home for the flat keys the format does not place.** Add a `ui` section to `config-format.ts`: `IYamlUiSection` on the document and a matching map on `IConfigFile`, holding the interface's own keys under the names the interface uses. It is written only when it holds something, like `desktop` and `news`. This is what stops an open-ended key such as a collapsible section's id being dropped, since those names are built by the component and cannot be declared in advance.

2. **Move the flat key/value view somewhere the phone can reach it.** `IAppConfig` and its conversions live in `app-config.ts`, which opens files and so cannot be bundled into the mobile worker. Split the conversions into a new `app-config-format.ts` that touches no filesystem, leaving `app-config.ts` with the functions that read and write the file, re-exporting the format half so existing importers do not change. The two views stay separate on purpose: `IConfigFile` fills in each feature's defaults, and the flat view must keep "absent" meaning absent, or a fresh install would be told syncing had already been switched off.

3. **Define the flat namespace once.** In `app-config-format.ts`, one list of the keys the document declares, and `getAppConfigValue` / `setAppConfigValue` that route a declared key to its field and any other key to the `ui` map. Both platforms' get/set pairs go through these, so a key cannot behave differently depending on which platform wrote it.

4. **Stop desktop dropping keys.** `get-config` and `set-config` in `apps/desktop/src/main.ts` call those two functions instead of indexing `IAppConfig` directly.

5. **Let the worker carry the flat keys and the news state.** Widen `read-config` to return the flat view and the news state alongside the sections it already returns, and `write-config` to accept a list of flat key writes and a news write. A write with no value clears the key, which is what `IConfig.clear` means, and is distinguishable from an absent entry because the value crosses the bridge as JSON. The handler already reads the whole document and replaces only what it was sent, so nothing else in the file is disturbed.

6. **Route mobile's flat config to that file.** Add an accessor to `mobile-config-file.ts` for the flat store, serialised the same way `mobile-config-store.ts` serialises its read-modify-write, since a get followed by a set is two round trips and `IConfig.add` is exactly that. `platform-provider-mobile.tsx` gives `createConfig` that accessor and stops binding `window.localStorage` for config. `getConfigValue`, `setConfigValue` and `CONFIG_KEY_PREFIX` lose their callers and go.

7. **Route mobile's news state to the same file.** Shown news ids and the last announced release move to the `news` section through the worker, so the phone records what it has shown in the same place and the same format as the other two platforms. `markUpdateAsShown` stops being an empty function. The available news feed stays in the WebView's own store: it is a fetched feed, not configuration, and desktop does not persist it either.

8. **Make what remains in local storage fail loudly.** The seeded news feed is the only thing left there. A stored value that will not parse is reported rather than silently replaced by an empty list, and a failed write throws an error naming the key rather than being ignored.

9. **Document the file.** Update the wiki page the format module points at, and `docs/` where it describes where settings live.

Not done, and why: the shown-news list is left uncapped, matching desktop. Dropping the oldest id would make that news item reappear, so a cap on this list is worse than none.

## Split into two files

The `ui` section above was the first sign of a distinction the one file was not making, and the file was then split along it. `config.yaml` holds what the user chose: the theme, developer mode, the frames-per-second overlay, the searches they saved, the automatic import settings and the syncing settings. `state.yaml` beside it holds what the app worked out for itself so the interface comes back the way it was left: the folders the dialogs reopen at, the searches merely run, whether the developer tools were open, how the gallery was sorted and how tall its rows are, which sidebar sections are collapsed, and what the notification system has already shown. Only the first is documented for users, because only the first is worth reading, hand-editing or carrying to another machine.

Nothing decides which file a key belongs to, because nothing has to. The interface has a context per store, `useConfig` and `useState`, and the caller asks the one it means: a collapsible section knows it is storing state and the theme toggle knows it is storing a setting. A first attempt kept one namespace and a list of key names to divide it at run time; that list was a thing to keep in step with two type definitions and it went.

Everything the WebView still kept moved with them: the gallery's sort order and row height, and the news feed the app has in hand. Nothing the app remembers is in the browser's own storage now. `use-client-id.ts` and the `clientId` field on `IDatabaseOpRecord` went instead of moving, because nothing called either: they were meant to tag database operations with the device that made them and that was never wired up. `local-storage.ts` went for the same reason.

Each platform provides both stores. The desktop app and the dev server pass the file's name on the channel they already had, rather than growing a second pair. A phone has one accessor per file in `mobile-config-file.ts`, over the `read-config` / `write-config` and `read-state` / `write-state` worker tasks.

## A socket race found on the way

The Android suite failed once on `45-s3-share-replica-sync` with "Socket is closed" out of the receiving device, after the sending CLI had reported success. It passed on its own and failed in company, which is contention rather than chance, so it was tracked down rather than run again.

`TcpHost` and `TlsHost` both take a connection out of their map and then close its socket when the remote goes away, while a write looks the socket up, releases nothing, and then writes. A write that took the socket out just before the reader closed it throws `SocketException: Socket is closed`, which is exactly the message that came out of the device, and which only Java's own `Socket.close()` produces. A write that arrives a moment later, once the connection is out of the map, is treated as a no-op and reported as success. So the same write got opposite answers depending on which side of that instant it landed, and the phone being busy is what widened the gap.

Both now answer the same way: when a write fails and the connection is no longer registered, the reader tore it down and the write had nowhere to go, so it reports success as the lookup miss already did. A failure on a connection that is still registered is still reported. The iOS `TcpHost` has the same race and gets the same check; the iOS `TlsHost` cannot hit it, because it hands its sends to `NWConnection` and discards the outcome.

## Unit Tests

- `config-format.ts`: the `ui` section round-trips, a malformed section reads as empty without costing the other sections, and an empty one is not written.
- `app-config-format.ts`: `getAppConfigValue` and `setAppConfigValue` route a declared key to its field and an undeclared key to the `ui` map, a cleared key is removed, and a key absent from both reads as undefined.
- `config.worker.ts`: `read-config` returns the flat view and the news state; `write-config` applies flat writes and a news write, leaves every other section as it was, and treats a write with no value as a clear.
- `mobile-config-store.ts`: a news feed that will not parse is reported and reads as empty, a valid one is unchanged, and a store whose write throws produces an error naming the key.

## Smoke Tests

- The existing Android suite already drives the settings that go through this path, so it is re-run rather than duplicated.
- `17-news-notifications` gains a restart: the item dismissed before it must not be announced again afterwards. That is the one thing no unit test can show, because it is the WebView's write actually reaching the file rather than an in-memory double.
- `52-reset-device` asserts `config.yaml` is gone as well as `databases.toml`, since the settings are in it now and a reset that left it would hand the next person the previous owner's.
- Not added: a desktop test for the saved searches and collapsed sections that used to be dropped. Driving them needs test ids on the search sidebar and the collapsible sections, which is scaffolding in production code and needs asking about first. They are covered by unit tests over the writer, and the IPC handler above it is two lines.

## Verify

- `mise exec -- bun run compile` exits 0.
- `mise exec -- bun run tev` exits 0.
- No remaining reader of `CONFIG_KEY_PREFIX`, and `window.localStorage` in `platform-provider-mobile.tsx` backs the news feed only.
