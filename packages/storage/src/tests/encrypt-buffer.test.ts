import { generateKeyPair, hashPublicKey } from "../lib/key-utils";
import { encryptBuffer, decryptBuffer, decryptNewFormat, decryptLegacy } from "../lib/encrypt-buffer";
import { ENCRYPTION_TAG, LEGACY_HEADER_LENGTH, NEW_FORMAT_HEADER_LENGTH } from "../lib/encryption-constants";

jest.mock("utils", () => ({
    log: {
        exception: jest.fn(),
    },
}));

describe("encrypt-buffer", () => {
    const keyPair = generateKeyPair();
    const keyMap: Record<string, import("node:crypto").KeyObject> = {
        default: keyPair.privateKey,
        [hashPublicKey(keyPair.publicKey).toString("hex")]: keyPair.privateKey,
    };

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
        it("returns data unchanged when new format but key not in map and no default key", () => {
            const plain = Buffer.from("secret");
            const encrypted = encryptBuffer(keyPair.publicKey, plain);
            const emptyMap: Record<string, import("node:crypto").KeyObject> = {};
            const result = decryptBuffer(encrypted, emptyMap);
            expect(result.equals(encrypted)).toBe(true);
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
