import { mapConnectionType } from "../../lib/network-info";

describe("mapConnectionType", () => {

    test("maps wifi and ethernet to wifi (unmetered, allowed under Wi-Fi-only)", () => {
        expect(mapConnectionType("wifi")).toBe("wifi");
        expect(mapConnectionType("ethernet")).toBe("wifi");
    });

    test("maps cellular to cellular (the only metered type)", () => {
        expect(mapConnectionType("cellular")).toBe("cellular");
    });

    test("maps none to none (offline)", () => {
        expect(mapConnectionType("none")).toBe("none");
    });

    test("maps unsupported, unknown, or absent values to unknown", () => {
        expect(mapConnectionType("unknown")).toBe("unknown");
        expect(mapConnectionType("wimax")).toBe("unknown");
        expect(mapConnectionType("bluetooth")).toBe("unknown");
        expect(mapConnectionType("other")).toBe("unknown");
        expect(mapConnectionType(undefined)).toBe("unknown");
        expect(mapConnectionType("")).toBe("unknown");
    });
});
