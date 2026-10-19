import { discoveryPort } from "../lib/lan-share-types";

//
// The value PHOTOSPHERE_LAN_SHARE_PORT had before each test, put back afterwards so no test leaks it into another.
//
let previousPort: string | undefined;

beforeEach(() => {
    previousPort = process.env.PHOTOSPHERE_LAN_SHARE_PORT;
});

afterEach(() => {
    if (previousPort === undefined) {
        delete process.env.PHOTOSPHERE_LAN_SHARE_PORT;
    }
    else {
        process.env.PHOTOSPHERE_LAN_SHARE_PORT = previousPort;
    }
});

test("the discovery port is 54321 when PHOTOSPHERE_LAN_SHARE_PORT is not set", () => {
    delete process.env.PHOTOSPHERE_LAN_SHARE_PORT;
    expect(discoveryPort()).toBe(54321);
});

test("the discovery port is the one PHOTOSPHERE_LAN_SHARE_PORT names", () => {
    process.env.PHOTOSPHERE_LAN_SHARE_PORT = "40123";
    expect(discoveryPort()).toBe(40123);
});

test("a PHOTOSPHERE_LAN_SHARE_PORT that is not a port number is refused with a sentence", () => {
    process.env.PHOTOSPHERE_LAN_SHARE_PORT = "abc";
    expect(() => discoveryPort()).toThrow("PHOTOSPHERE_LAN_SHARE_PORT must be a port number, not \"abc\".");
});

test("a PHOTOSPHERE_LAN_SHARE_PORT above the largest port is refused", () => {
    process.env.PHOTOSPHERE_LAN_SHARE_PORT = "70000";
    expect(() => discoveryPort()).toThrow("PHOTOSPHERE_LAN_SHARE_PORT must be a port number, not \"70000\".");
});
