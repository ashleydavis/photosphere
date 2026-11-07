# Move app logic out of the Ziggy platform provider

`apps/photosphere-frontend/src/lib/platform-provider-ziggy.tsx` still holds app logic that is the same on every platform. Each refactor below moves one piece of it to the shared UI in `packages/user-interface`, as its own change, tested with `bun run tev` and committed before the next one starts.

1. **Background import sentence.** Move the sentence that says what automatic import does while the app is off screen into `components/auto-import-settings.tsx`. The platform context drops `backgroundImportDescription` and gives `platformKind` and `os` instead, and the card picks the sentence from those.

2. **Drag and drop flag.** Drop `supportsDragAndDropImport` from the platform context. `pages/import/import-page.tsx` checks `platformKind === "desktop"` itself. Needs refactor 1 for `platformKind`.

3. **Copy to clipboard.** Drop `copyToClipboard` from the platform context. `components/asset-view.tsx` converts the image to PNG and writes it to the clipboard itself, and does nothing on a phone. Needs refactor 1 for `platformKind`.

4. **Import progress logging.** Move the effect that logs each new import progress line into `main.tsx`, which is always mounted and already listens to task messages.

5. **Starting sync settings.** Move the call to `seedSyncSettings` on startup into `context/sync-context.tsx`. Moves `lib/mobile-settings.ts` and `lib/background-work.ts`, with their tests, into `packages/user-interface`.

6. **Sync database record.** Move the call to `recordSyncDatabase` out of `notifyDatabaseOpened` into `context/sync-context.tsx`, run when a database is opened. Needs refactor 5.

7. **Background work decision.** Move `ensureAutoImport` and `ensureAutoImportOnce` into `context/sync-context.tsx`, keeping the TODO that says the re-check belongs in the core. The provider keeps only three Ziggy calls as platform members: `requestMediaPermission`, `startBackgroundImport` and `stopBackgroundImport`. Needs refactors 5 and 6.
    - Open question: what re-checks the background work after a setting is written. Today the provider's config writer calls it directly. A callback list on the config store was tried and removed.
