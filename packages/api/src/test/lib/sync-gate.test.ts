import { computeSyncAllowed } from "../../lib/sync-gate";

describe("computeSyncAllowed", () => {

    test("returns false when syncing is disabled, regardless of other inputs", () => {
        expect(computeSyncAllowed({ syncEnabled: false, syncOnlyOnWifi: false, connected: true, connectionType: "wifi" })).toBe(false);
        expect(computeSyncAllowed({ syncEnabled: false, syncOnlyOnWifi: true, connected: true, connectionType: "cellular" })).toBe(false);
    });

    test("returns false when offline even if enabled", () => {
        expect(computeSyncAllowed({ syncEnabled: true, syncOnlyOnWifi: false, connected: false, connectionType: "wifi" })).toBe(false);
    });

    test("returns false when the connection type is none", () => {
        expect(computeSyncAllowed({ syncEnabled: true, syncOnlyOnWifi: false, connected: true, connectionType: "none" })).toBe(false);
    });

    test("returns false when Wi-Fi-only is on and the connection is cellular", () => {
        expect(computeSyncAllowed({ syncEnabled: true, syncOnlyOnWifi: true, connected: true, connectionType: "cellular" })).toBe(false);
    });

    test("returns true when Wi-Fi-only is on and the connection is wifi", () => {
        expect(computeSyncAllowed({ syncEnabled: true, syncOnlyOnWifi: true, connected: true, connectionType: "wifi" })).toBe(true);
    });

    test("returns true when Wi-Fi-only is on and the connection type is unknown (desktop/web)", () => {
        expect(computeSyncAllowed({ syncEnabled: true, syncOnlyOnWifi: true, connected: true, connectionType: "unknown" })).toBe(true);
    });

    test("returns true when Wi-Fi-only is off and the connection is cellular", () => {
        expect(computeSyncAllowed({ syncEnabled: true, syncOnlyOnWifi: false, connected: true, connectionType: "cellular" })).toBe(true);
    });

    test("returns true when fully enabled, connected, and on wifi", () => {
        expect(computeSyncAllowed({ syncEnabled: true, syncOnlyOnWifi: true, connected: true, connectionType: "wifi" })).toBe(true);
    });
});
