import { getFsHost, codedError, base64ToBuffer, callHost, makeHostErrorEnvelope } from "../../shims/host-access";

//
// Unit tests for the fs-shim host accessor and marshalling helpers.
//
describe("host-access helpers", () => {

    afterEach(() => {
        (globalThis as any).host = undefined;
    });

    test("getFsHost returns the installed host", () => {
        const fakeHost = { fsReadFile: () => null };
        (globalThis as any).host = fakeHost;
        expect(getFsHost()).toBe(fakeHost);
    });

    test("getFsHost throws a clear error when the host bridge is missing", () => {
        (globalThis as any).host = undefined;
        expect(() => getFsHost()).toThrow(/host bridge .* is not installed/);
    });

    test("codedError attaches the Node-style code", () => {
        const error = codedError("ENOENT", "missing");
        expect(error.code).toBe("ENOENT");
        expect(error.message).toBe("missing");
    });

    test("base64ToBuffer decodes base64 to the original bytes", () => {
        const original = Buffer.from([10, 20, 30, 200, 255]);
        const decoded = base64ToBuffer(original.toString("base64"));
        expect(decoded.equals(original)).toBe(true);
    });

    test("callHost returns a normal value unchanged", () => {
        expect(callHost(() => "aGk=")).toBe("aGk=");
        expect(callHost(() => null)).toBeNull();
        expect(callHost(() => true)).toBe(true);
    });

    test("callHost throws a coded error when the host returns an error envelope", () => {
        expect(() => callHost(() => makeHostErrorEnvelope("EEXIST", "file already exists")))
            .toThrow(expect.objectContaining({ code: "EEXIST", message: "file already exists" }));
        expect(() => callHost(() => makeHostErrorEnvelope("ENOENT", "missing")))
            .toThrow(expect.objectContaining({ code: "ENOENT" }));
    });

    test("makeHostErrorEnvelope round-trips through callHost", () => {
        const envelope = makeHostErrorEnvelope("ENOENT", "missing file");
        expect(envelope.startsWith("@@HOSTERR@@")).toBe(true);
        expect(() => callHost(() => envelope))
            .toThrow(expect.objectContaining({ code: "ENOENT", message: "missing file" }));
    });

    test("callHost maps a thrown error, inferring the code from the message", () => {
        expect(() => callHost(() => { throw new Error("EEXIST: boom"); }))
            .toThrow(expect.objectContaining({ code: "EEXIST" }));
        expect(() => callHost(() => { throw new Error("something else"); }))
            .toThrow(expect.objectContaining({ code: "EHOST" }));
    });

    test("a real base64 or JSON result is never mistaken for an error envelope", () => {
        // Base64 cannot contain '@'; JSON values start with { or [.
        expect(callHost(() => "SGVsbG8=")).toBe("SGVsbG8=");
        expect(callHost(() => '{"size":5}')).toBe('{"size":5}');
    });
});
