import { createPublicKey, generateKeyPairSync } from "node:crypto";
import { generateKeyPair, hashPublicKey } from "../lib/key-utils";
import { encryptBuffer, decryptBuffer, decryptNewFormat, decryptLegacy } from "../lib/encrypt-buffer";
import { ENCRYPTION_TAG, LEGACY_HEADER_LENGTH, NEW_FORMAT_HEADER_LENGTH } from "../lib/encryption-constants";

jest.mock("utils", () => ({
    log: {
        exception: jest.fn(),
        verbose: jest.fn(),
    },
}));

describe("encrypt-buffer", () => {
    const keyPair = generateKeyPair();
    const keyMap: Record<string, import("node:crypto").KeyObject> = {
        default: keyPair.privateKey,
        [hashPublicKey(keyPair.publicKey).toString("hex")]: keyPair.privateKey,
    };

    describe("a key the format cannot read back", () => {

        // 2048-bit RSA wraps the AES key into 256 bytes, and every reader slices it out of the file
        // at a fixed 512, which is an RSA-4096 block. So a file written with a smaller key can never
        // be decrypted by this codebase.
        const smallKeyPair = generateKeyPairSync("rsa", {
            modulusLength: 2048,
            publicKeyEncoding: {
                type: "spki",
                format: "pem",
            },
            privateKeyEncoding: {
                type: "pkcs8",
                format: "pem",
            },
        });

        test("is refused at the write rather than producing a file nothing can decrypt", () => {
            // The write is where this has to fail. Encrypting with such a key used to succeed and say
            // nothing, and making the read loud does not get the data back: by the time the read
            // fails the only copy of the plaintext is the unreadable file.
            expect(() => encryptBuffer(createPublicKey(smallKeyPair.publicKey), Buffer.from("secret")))
                .toThrow(/wraps into 256 bytes and the file format requires 512/);
        });
    });

    describe("new format round-trip", () => {
        it("encrypts and decrypts with key map", async () => {
            const plain = Buffer.from("hello world");
            const encrypted = encryptBuffer(keyPair.publicKey, plain);
            expect(encrypted.slice(0, 4).toString("ascii")).toBe(ENCRYPTION_TAG);
            const decrypted = decryptBuffer(encrypted, keyMap);
            expect(decrypted.equals(plain)).toBe(true);
        });
    });

    describe("legacy format (no header)", () => {
        it("decrypts legacy payload using default key", async () => {
            const plain = Buffer.from("legacy payload");
            const encrypted = encryptBuffer(keyPair.publicKey, plain);
            const legacyPayload = encrypted.slice(44);
            const decrypted = decryptBuffer(legacyPayload, keyMap);
            expect(decrypted.equals(plain)).toBe(true);
        });
    });

    describe("new format with key hash lookup", () => {
        it("decrypts new-format payload using hash key in map", async () => {
            const plain = Buffer.from("new format");
            const encrypted = encryptBuffer(keyPair.publicKey, plain);
            const decrypted = decryptBuffer(encrypted, keyMap);
            expect(decrypted.equals(plain)).toBe(true);
        });
    });

    describe("errors", () => {
        test("throws when the data says it is encrypted and the key is not in the map", () => {
            // It used to hand the ciphertext back, on the reading that a failed decryption means the
            // data was never encrypted. For data carrying the encryption tag that reading is wrong,
            // and it turns a missing key into a wrong answer somewhere else entirely: the caller
            // deserializes the ciphertext and reports whatever it happens to look like. A database
            // file read this way reports "Checksum mismatch", which names serialization and says
            // nothing about the key.
            const plain = Buffer.from("secret");
            const encrypted = encryptBuffer(keyPair.publicKey, plain);
            const emptyMap: Record<string, import("node:crypto").KeyObject> = {};
            expect(() => decryptBuffer(encrypted, emptyMap)).toThrow(/says it is encrypted/);
        });

        test("throws when the data says it is encrypted and the wrong key is in the map", () => {
            const otherKeyPair = generateKeyPair();
            const plain = Buffer.from("secret");
            const encrypted = encryptBuffer(keyPair.publicKey, plain);
            const wrongMap: Record<string, import("node:crypto").KeyObject> = {
                default: otherKeyPair.privateKey,
                [hashPublicKey(otherKeyPair.publicKey).toString("hex")]: otherKeyPair.privateKey,
            };
            expect(() => decryptBuffer(encrypted, wrongMap)).toThrow(/says it is encrypted/);
        });

        test("still hands back a plaintext buffer unchanged, which is how an unencrypted file reads", () => {
            // The case the fallback exists for, and the reason it cannot simply be removed: a
            // database can hold files that were never encrypted, read through the same storage.
            const plain = Buffer.from("this was never encrypted, and is long enough to look like a file");
            const result = decryptBuffer(plain, keyMap);
            expect(result.equals(plain)).toBe(true);
        });

        it("returns data unchanged when legacy data and no default key", () => {
            const plain = Buffer.from("x");
            const encrypted = encryptBuffer(keyPair.publicKey, plain);
            const legacyPayload = encrypted.slice(44);
            const noDefaultMap: Record<string, import("node:crypto").KeyObject> = {
                [hashPublicKey(keyPair.publicKey).toString("hex")]: keyPair.privateKey,
            };
            const result = decryptBuffer(legacyPayload, noDefaultMap);
            expect(result.equals(legacyPayload)).toBe(true);
        });

        it("returns data unchanged when shorter than 4 bytes", () => {
            const short = Buffer.alloc(2);
            const result = decryptBuffer(short, keyMap);
            expect(result.equals(short)).toBe(true);
        });
    });

    describe("decryptNewFormat", () => {
        it("throws when data too short for header", () => {
            const short = Buffer.alloc(NEW_FORMAT_HEADER_LENGTH - 1);
            Buffer.from(ENCRYPTION_TAG, "ascii").copy(short, 0);
            expect(() => decryptNewFormat(short, keyMap)).toThrow(/too short for header/);
        });

        it("throws when data does not start with encryption tag", () => {
            const buf = Buffer.alloc(NEW_FORMAT_HEADER_LENGTH);
            buf.write("XXXX", 0);
            expect(() => decryptNewFormat(buf, keyMap)).toThrow(/does not start with encryption tag/);
        });

        it("throws when key not in map", () => {
            const encrypted = encryptBuffer(keyPair.publicKey, Buffer.from("secret"));
            const emptyMap: Record<string, import("node:crypto").KeyObject> = {};
            expect(() => decryptNewFormat(encrypted, emptyMap)).toThrow(/No private key in map/);
        });

        it("decrypts valid new-format buffer when key in map", () => {
            const plain = Buffer.from("new format payload");
            const encrypted = encryptBuffer(keyPair.publicKey, plain);
            const decrypted = decryptNewFormat(encrypted, keyMap);
            expect(decrypted.equals(plain)).toBe(true);
        });
    });

    describe("decryptLegacy", () => {
        it("throws when data too short for legacy header", () => {
            const short = Buffer.alloc(LEGACY_HEADER_LENGTH - 1);
            expect(() => decryptLegacy(short, keyPair.privateKey)).toThrow(/too short/);
        });

        it("decrypts valid legacy payload", () => {
            const plain = Buffer.from("legacy content");
            const encrypted = encryptBuffer(keyPair.publicKey, plain);
            const legacyPayload = encrypted.slice(44);
            const decrypted = decryptLegacy(legacyPayload, keyPair.privateKey);
            expect(decrypted.equals(plain)).toBe(true);
        });
    });
});
