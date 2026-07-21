import { createHash as nodeCreateHash } from "crypto";
import { Buffer } from "buffer";
import { createHash, createSign, generateKeyPairSync, randomUUID } from "../../shims/node-crypto";

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

//
// Unit tests for the RSA keygen/sign functions, which LAN-share's receiver uses to self-sign its TLS
// certificate. They delegate to native host functions, so these verify the plumbing against a mock host.
//
describe("node-crypto shim RSA keygen/sign", () => {

    afterEach(() => {
        delete (globalThis as any).host;
    });

    test("generateKeyPairSync calls cryptoGenerateRsaKeyPair with the modulus length and maps the PEMs", () => {
        const cryptoGenerateRsaKeyPair = jest.fn().mockReturnValue(JSON.stringify({ privateKeyPem: "PRIV-PEM", publicKeyPem: "PUB-PEM" }));
        (globalThis as any).host = { cryptoGenerateRsaKeyPair };

        const result = generateKeyPairSync("rsa", {
            modulusLength: 2048,
            publicKeyEncoding: { type: "spki", format: "pem" },
            privateKeyEncoding: { type: "pkcs8", format: "pem" },
        });

        expect(cryptoGenerateRsaKeyPair).toHaveBeenCalledWith(2048);
        expect(result.publicKey).toBe("PUB-PEM");
        expect(result.privateKey).toBe("PRIV-PEM");
    });

    test("createSign accumulates update() data and signs it via cryptoSignSha256, decoding the signature", () => {
        const signatureBytes = Buffer.from("the-signature-bytes");
        const cryptoSignSha256 = jest.fn().mockReturnValue(signatureBytes.toString("base64"));
        (globalThis as any).host = { cryptoSignSha256 };

        const signature = createSign("SHA256").update(Buffer.from("hello ")).update("world").sign("PRIVATE-KEY-PEM");

        expect(cryptoSignSha256).toHaveBeenCalledWith("PRIVATE-KEY-PEM", Buffer.from("hello world").toString("base64"));
        expect(signature.equals(signatureBytes)).toBe(true);
    });
});

//
// Unit tests for the shim's randomUUID, used by node-utils outputFile to name temp files.
//
describe("node-crypto shim randomUUID", () => {

    test("produces a well-formed v4 UUID", () => {
        expect(randomUUID()).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    });

    test("produces distinct values across calls", () => {
        const generated = new Set(Array.from({ length: 100 }, () => randomUUID()));
        expect(generated.size).toBe(100);
    });
});
