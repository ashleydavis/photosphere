import {
    createHash as nodeCreateHash,
    createHmac as nodeCreateHmac,
    publicEncrypt as nodePublicEncrypt,
    privateDecrypt as nodePrivateDecrypt,
    createPublicKey as nodeCreatePublicKey,
    generateKeyPairSync as nodeGenerateKeyPairSync,
} from "crypto";
import * as fs from "fs";
import * as path from "path";
import { Buffer } from "buffer";
import {
    createHash,
    createHmac,
    createSign,
    sign,
    generateKeyPairSync,
    createCipheriv,
    createDecipheriv,
    createPrivateKey,
    createPublicKey,
    publicEncrypt,
    privateDecrypt,
    randomBytes,
    randomUUID,
    KeyObject,
} from "../../shims/node-crypto";

//
// Installs a mock native crypto host backed by real Node crypto: the RSA host functions the shim calls
// (cryptoPublicEncryptOaepSha1 / cryptoPrivateDecryptOaepSha1 / cryptoPublicKeyFromPrivate) are
// implemented with Node's default OAEP-SHA1 padding, exactly what the native Java/Swift host functions
// must do. This proves the shim's plumbing and the on-disk format without a device.
//
function installMockCryptoHost(): void {
    (globalThis as any).host = {
        platform: "android",
        cryptoPublicEncryptOaepSha1: (publicKeyPem: string, dataBase64: string): string =>
            nodePublicEncrypt(publicKeyPem, Buffer.from(dataBase64, "base64")).toString("base64"),
        cryptoPrivateDecryptOaepSha1: (privateKeyPem: string, dataBase64: string): string =>
            nodePrivateDecrypt(privateKeyPem, Buffer.from(dataBase64, "base64")).toString("base64"),
        cryptoPublicKeyFromPrivate: (privateKeyPem: string): string =>
            nodeCreatePublicKey(privateKeyPem).export({ type: "spki", format: "pem" }) as string,
    };
}

//
// The directory holding the checked-in desktop-produced encrypted fixtures.
//
const FIXTURE_DIR = path.join(__dirname, "..", "fixtures", "encrypted");

//
// Decrypts a new-format encrypted payload ([44-byte header][512 RSA-encrypted key][16 IV][ciphertext])
// using ONLY the shim primitives, mirroring decryptNewFormat. This is what proves the shim decrypts
// desktop-produced bytes: shim privateDecrypt (native OAEP-SHA1) + shim createDecipheriv (AES-256-CBC).
//
function decryptFixtureWithShim(data: Buffer, privateKey: KeyObject): Buffer {
    const payload = data.subarray(44);
    const encryptedKey = payload.subarray(0, 512);
    const iv = payload.subarray(512, 512 + 16);
    const ciphertext = payload.subarray(512 + 16);
    const key = privateDecrypt(privateKey, encryptedKey);
    const decipher = createDecipheriv("aes-256-cbc", key, iv);
    return Buffer.concat([decipher.update(ciphertext), decipher.final()]);
}

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

    test("sign() signs in one call through the same native signer, decoding the signature", () => {
        const signatureBytes = Buffer.from("one-shot-signature");
        const cryptoSignSha256 = jest.fn().mockReturnValue(signatureBytes.toString("base64"));
        (globalThis as any).host = { cryptoSignSha256 };

        const signature = sign("sha256", Buffer.from("payload"), "PRIVATE-KEY-PEM");

        expect(cryptoSignSha256).toHaveBeenCalledWith("PRIVATE-KEY-PEM", Buffer.from("payload").toString("base64"));
        expect(signature.equals(signatureBytes)).toBe(true);
    });

    test("sign() accepts the SHA-256 spellings Node accepts", () => {
        (globalThis as any).host = { cryptoSignSha256: (): string => Buffer.from("s").toString("base64") };

        expect(() => sign("SHA256", Buffer.from("x"), "PEM")).not.toThrow();
        expect(() => sign("sha-256", Buffer.from("x"), "PEM")).not.toThrow();
    });

    test("sign() refuses a digest the native signer cannot produce, rather than signing wrongly", () => {
        (globalThis as any).host = { cryptoSignSha256: (): string => "" };

        expect(() => sign("sha512", Buffer.from("x"), "PEM")).toThrow(/sha256/);
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

//
// randomBytes / AES-256-CBC / HMAC: the pure-JS symmetric path the encryption bulk work uses.
//
describe("node-crypto shim symmetric + hmac", () => {

    test("randomBytes returns the requested length and is not constant", () => {
        const first = randomBytes(32);
        const second = randomBytes(32);
        expect(first.length).toBe(32);
        expect(second.length).toBe(32);
        // Not all zero and not equal to a second draw (basic distribution sanity).
        expect(first.equals(Buffer.alloc(32))).toBe(false);
        expect(first.equals(second)).toBe(false);
    });

    test("AES-256-CBC round-trips a buffer", () => {
        const key = randomBytes(32);
        const iv = randomBytes(16);
        const plaintext = Buffer.from("the quick brown fox jumps over the lazy dog, repeatedly.", "utf8");
        const cipher = createCipheriv("aes-256-cbc", key, iv);
        const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()]);
        const decipher = createDecipheriv("aes-256-cbc", key, iv);
        const decrypted = Buffer.concat([decipher.update(encrypted), decipher.final()]);
        expect(decrypted.equals(plaintext)).toBe(true);
    });

    test("createHmac('sha256') matches Node crypto and is reachable as a named export", () => {
        const key = Buffer.from("signing-key");
        const data = Buffer.from("string-to-sign");
        const shimHex = createHmac("sha256", key).update(data).digest("hex");
        const nodeHex = nodeCreateHmac("sha256", key).update(data).digest("hex");
        expect(shimHex).toBe(nodeHex);
    });
});

//
// RSA via the native host: publicEncrypt / privateDecrypt round-trip and KeyObject.export (PEM + DER).
//
describe("node-crypto shim RSA + KeyObject", () => {

    afterEach(() => {
        delete (globalThis as any).host;
    });

    test("publicEncrypt/privateDecrypt round-trip an AES key through the native OAEP-SHA1 host", () => {
        installMockCryptoHost();
        const { publicKey, privateKey } = nodeGenerateKeyPairSync("rsa", {
            modulusLength: 4096,
            publicKeyEncoding: { type: "spki", format: "pem" },
            privateKeyEncoding: { type: "pkcs8", format: "pem" },
        });
        const publicKeyObject = createPublicKey(publicKey);
        const privateKeyObject = createPrivateKey(privateKey);

        const secret = randomBytes(32);
        const encrypted = publicEncrypt(publicKeyObject, secret);
        const decrypted = privateDecrypt(privateKeyObject, encrypted);
        expect(decrypted.equals(secret)).toBe(true);
    });

    test("KeyObject.export returns the PEM for format 'pem' and exact DER for format 'der'", () => {
        const { publicKey } = nodeGenerateKeyPairSync("rsa", {
            modulusLength: 2048,
            publicKeyEncoding: { type: "spki", format: "pem" },
            privateKeyEncoding: { type: "pkcs8", format: "pem" },
        });
        const publicKeyObject = createPublicKey(publicKey);

        expect(publicKeyObject.export({ type: "spki", format: "pem" })).toBe(publicKey);

        const shimDer = publicKeyObject.export({ type: "spki", format: "der" }) as Buffer;
        const nodeDer = nodeCreatePublicKey(publicKey).export({ type: "spki", format: "der" }) as Buffer;
        expect(Buffer.isBuffer(shimDer)).toBe(true);
        expect(shimDer.equals(nodeDer)).toBe(true);
    });

    test("createPublicKey derives the public key from a private KeyObject via the native host", () => {
        installMockCryptoHost();
        const { publicKey, privateKey } = nodeGenerateKeyPairSync("rsa", {
            modulusLength: 2048,
            publicKeyEncoding: { type: "spki", format: "pem" },
            privateKeyEncoding: { type: "pkcs8", format: "pem" },
        });
        const derivedPublic = createPublicKey(createPrivateKey(privateKey));
        expect(derivedPublic.export({ type: "spki", format: "pem" })).toBe(publicKey);
    });
});

//
// The checked-in desktop fixtures: the only test that catches an OAEP padding mismatch. The mobile
// shim (native OAEP-SHA1 host + AES-256-CBC) must decrypt bytes produced by Node's real encryption.
//
describe("node-crypto shim decrypts the desktop fixtures", () => {

    afterEach(() => {
        delete (globalThis as any).host;
    });

    test("decrypts the encrypted-buffer fixture to its expected plaintext", () => {
        installMockCryptoHost();
        const privateKeyPem = fs.readFileSync(path.join(FIXTURE_DIR, "test-only-do-not-use.private.pem"), "utf8");
        const privateKeyObject = createPrivateKey(privateKeyPem);
        const encrypted = fs.readFileSync(path.join(FIXTURE_DIR, "buffer.encrypted.bin"));
        const expected = fs.readFileSync(path.join(FIXTURE_DIR, "buffer.plaintext.txt"));
        const decrypted = decryptFixtureWithShim(encrypted, privateKeyObject);
        expect(decrypted.equals(expected)).toBe(true);
    });

    test("decrypts the encrypted-stream fixture to its expected plaintext", () => {
        installMockCryptoHost();
        const privateKeyPem = fs.readFileSync(path.join(FIXTURE_DIR, "test-only-do-not-use.private.pem"), "utf8");
        const privateKeyObject = createPrivateKey(privateKeyPem);
        const encrypted = fs.readFileSync(path.join(FIXTURE_DIR, "stream.encrypted.bin"));
        const expected = fs.readFileSync(path.join(FIXTURE_DIR, "stream.plaintext.txt"));
        const decrypted = decryptFixtureWithShim(encrypted, privateKeyObject);
        expect(decrypted.equals(expected)).toBe(true);
    });
});
