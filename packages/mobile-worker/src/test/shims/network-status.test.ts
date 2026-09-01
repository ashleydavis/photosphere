import { readNetworkConnectionType, toNetworkConnectionType } from "../../shims/network-status";
import { makeHostErrorEnvelope } from "../../shims/host-access";

//
// Tests for the TypeScript side of the connection-type host function.
//
// computeSyncAllowed treats "cellular" as the one type to refuse and "unknown" as permitted, so what
// this mapping does with a value it does not recognise decides whether a phone reporting something
// new stops syncing altogether or carries on. It carries on.
//

afterEach(() => {
    delete (globalThis as any).host;
});

//
// Installs a native host bridge reporting the given value.
//
function setHostReporting(reported: string): void {
    (globalThis as any).host = {
        networkConnectionType: () => reported,
    };
}

describe("connection type", () => {

    test("each value the platforms report maps to itself", () => {
        expect(toNetworkConnectionType("wifi")).toBe("wifi");
        expect(toNetworkConnectionType("cellular")).toBe("cellular");
        expect(toNetworkConnectionType("none")).toBe("none");
        expect(toNetworkConnectionType("unknown")).toBe("unknown");
    });

    test("anything unrecognised maps to unknown rather than throwing", () => {
        // A platform reporting a transport nobody anticipated must not stop syncing, and "unknown" is
        // the value computeSyncAllowed already permits for exactly this reason.
        expect(toNetworkConnectionType("ethernet")).toBe("unknown");
        expect(toNetworkConnectionType("")).toBe("unknown");
        expect(toNetworkConnectionType("WIFI")).toBe("unknown");
    });

    test("reading goes to the host and comes back as a type computeSyncAllowed knows", () => {
        setHostReporting("cellular");

        expect(readNetworkConnectionType()).toBe("cellular");
    });

    test("reading with no host installed says so rather than answering", () => {
        // A missing bridge means this was called outside the embedded worker. Answering "unknown"
        // would be a guess that permits syncing, which is the wrong way to be wrong.
        expect(() => readNetworkConnectionType()).toThrow("host");
    });

    test("a host error envelope is thrown rather than read as a connection type", () => {
        // The native side returns errors as an envelope string instead of throwing across the bridge.
        // Taken at face value it would map to "unknown" and permit a sync on a connection nobody
        // could identify.
        (globalThis as any).host = {
            networkConnectionType: () => makeHostErrorEnvelope("EHOST", "no connectivity manager"),
        };

        expect(() => readNetworkConnectionType()).toThrow("no connectivity manager");
    });
});
