import { shouldSyncAfterEdit } from "../lib/mobile-edit-sync";

//
// Tests for the one sync the mobile WebView still starts.
//
// This is what is left of the deleted sync scheduler, and it keeps the part of it that mattered:
// asking whether an automatic sync is permitted at all. An edit that synced regardless would push
// photos over a cellular connection after the user had switched "Only sync over Wi-Fi" on, which is
// the setting people notice on their bill.
//

describe("syncing after an edit", () => {

    test("an edit to an open database syncs when syncing is permitted", () => {
        expect(shouldSyncAfterEdit({
            syncAllowed: true,
            databasePath: "photosphere-default",
            syncInFlight: false,
        })).toBe(true);
    });

    test("an edit does not sync when syncing is not permitted", () => {
        // Not permitted covers syncing switched off, no network, and a cellular connection while the
        // Wi-Fi-only restriction is on.
        expect(shouldSyncAfterEdit({
            syncAllowed: false,
            databasePath: "photosphere-default",
            syncInFlight: false,
        })).toBe(false);
    });

    test("no open database means no sync", () => {
        expect(shouldSyncAfterEdit({
            syncAllowed: true,
            databasePath: undefined,
            syncInFlight: false,
        })).toBe(false);

        expect(shouldSyncAfterEdit({
            syncAllowed: true,
            databasePath: "",
            syncInFlight: false,
        })).toBe(false);
    });

    test("a sync already running means no second one", () => {
        // A second sync would queue behind the first holding an engine slot, and would then find the
        // first had already pushed everything.
        expect(shouldSyncAfterEdit({
            syncAllowed: true,
            databasePath: "photosphere-default",
            syncInFlight: true,
        })).toBe(false);
    });
});
