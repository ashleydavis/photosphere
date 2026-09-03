import { planBackgroundWork } from "../lib/background-work";

//
// Tests for what the app asks the native side to run in the background.
//
// The case that matters most is syncing on its own. The two loops share one Android foreground
// service, and tying them to the import's setting made background syncing need automatic import
// switched on as well, which nobody asked for: a user who imports by hand and wants their edits
// pushed is not asking for their photo library to be scanned.
//

describe("planning the background work", () => {

    test("automatic import on its own runs it", () => {
        const decision = planBackgroundWork({ autoImportEnabled: true, syncEnabled: false, hasDatabaseToSync: false });

        expect(decision.shouldRun).toBe(true);
    });

    test("syncing on its own runs it", () => {
        const decision = planBackgroundWork({ autoImportEnabled: false, syncEnabled: true, hasDatabaseToSync: true });

        expect(decision.shouldRun).toBe(true);
    });

    test("both on runs it", () => {
        const decision = planBackgroundWork({ autoImportEnabled: true, syncEnabled: true, hasDatabaseToSync: true });

        expect(decision.shouldRun).toBe(true);
    });

    test("both off is the only thing that stops it", () => {
        // The ongoing notification goes with it, so a phone that has opted into neither must not be
        // left carrying one.
        const decision = planBackgroundWork({ autoImportEnabled: false, syncEnabled: false, hasDatabaseToSync: true });

        expect(decision.shouldRun).toBe(false);
    });

    test("syncing on its own never asks for the photo library", () => {
        // Syncing moves what is already in the database. Asking a user who only syncs for access to
        // their photos would be asking for something the feature does not use.
        const decision = planBackgroundWork({ autoImportEnabled: false, syncEnabled: true, hasDatabaseToSync: true });

        expect(decision.needsMediaPermission).toBe(false);
    });

    test("automatic import asks for the photo library", () => {
        const decision = planBackgroundWork({ autoImportEnabled: true, syncEnabled: false, hasDatabaseToSync: false });

        expect(decision.needsMediaPermission).toBe(true);
    });

    test("syncing with nothing to sync runs nothing", () => {
        // A phone that has never opened a database has nothing to push, and syncing defaults to on,
        // so this is every fresh install. Starting a service for it would put an ongoing
        // notification on the screen to do nothing at all.
        const decision = planBackgroundWork({ autoImportEnabled: false, syncEnabled: true, hasDatabaseToSync: false });

        expect(decision.shouldRun).toBe(false);
    });

    test("automatic import runs it even with nothing to sync", () => {
        // Automatic import makes its own database, so it never needs one to exist first.
        const decision = planBackgroundWork({ autoImportEnabled: true, syncEnabled: true, hasDatabaseToSync: false });

        expect(decision.shouldRun).toBe(true);
    });
});
