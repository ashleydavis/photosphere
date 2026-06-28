import { createHash as nodeCreateHash } from "crypto";
import { createHash } from "../../shims/node-crypto";

//
// Unit tests for the crypto shim's sha256, which serialization uses to verify file checksums.
// Correctness is checked against a known vector and against Node's own crypto for random input.
//
describe("node-crypto shim createHash('sha256')", () => {

    test("matches the known SHA-256 vector for 'abc'", () => {
        const digestHex = createHash("sha256").update(Buffer.from("abc", "utf8")).digest("hex");
        expect(digestHex).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    });

    test("digest() returns a 32-byte Buffer equal to the hex digest", () => {
        const hash = createHash("sha256").update(Buffer.from("photosphere", "utf8"));
        const digestBuffer = hash.digest() as Buffer;
        expect(Buffer.isBuffer(digestBuffer)).toBe(true);
        expect(digestBuffer.length).toBe(32);

        const expectedHex = createHash("sha256").update(Buffer.from("photosphere", "utf8")).digest("hex");
        expect(digestBuffer.toString("hex")).toBe(expectedHex);
    });

    test("matches Node crypto for random binary input", () => {
        const data = Buffer.from([0, 1, 2, 250, 251, 255, 127, 128]);
        const shimHex = createHash("sha256").update(data).digest("hex");
        const nodeHex = nodeCreateHash("sha256").update(data).digest("hex");
        expect(shimHex).toBe(nodeHex);
    });

    test("accepts a string update like Node", () => {
        const shimHex = createHash("sha256").update("hello").digest("hex");
        const nodeHex = nodeCreateHash("sha256").update("hello").digest("hex");
        expect(shimHex).toBe(nodeHex);
    });

    test("supports md5, matching Node crypto", () => {
        const data = Buffer.from("photosphere", "utf8");
        expect(createHash("md5").update(data).digest("hex"))
            .toBe(nodeCreateHash("md5").update(data).digest("hex"));
    });
});
