import { generateKeyPair, hashPublicKey } from "../lib/key-utils";
import { encryptBuffer, decryptBuffer } from "../lib/encrypt-buffer";
import { ENCRYPTION_TAG } from "../lib/encryption-constants";

describe("encrypt-buffer", () => {
    const keyPair = generateKeyPair();
    const keyMap: Record<string, import("node:crypto").KeyObject> = {
        default: keyPair.privateKey,
        [hashPublicKey(keyPair.publicKey).toString("hex")]: keyPair.privateKey,
    };

    describe("new format round-trip", () => {
        it("encrypts and decrypts with key map", async () => {
            const plain = Buffer.from("hello world");
            const encrypted = await encryptBuffer(keyPair.publicKey, plain);
            expect(encrypted.slice(0, 4).toString("ascii")).toBe(ENCRYPTION_TAG);
            const decrypted = await decryptBuffer(encrypted, keyMap);
            expect(decrypted.equals(plain)).toBe(true);
        });
    });

    describe("legacy format (no header)", () => {
        it("decrypts legacy payload using default key", async () => {
            const plain = Buffer.from("legacy payload");
            const encrypted = await encryptBuffer(keyPair.publicKey, plain);
            const legacyPayload = encrypted.slice(44);
            const decrypted = await decryptBuffer(legacyPayload, keyMap);
            expect(decrypted.equals(plain)).toBe(true);
        });
    });

    describe("new format with key hash lookup", () => {
        it("decrypts new-format payload using hash key in map", async () => {
            const plain = Buffer.from("new format");
            const encrypted = await encryptBuffer(keyPair.publicKey, plain);
            const decrypted = await decryptBuffer(encrypted, keyMap);
            expect(decrypted.equals(plain)).toBe(true);
        });
    });

    describe("errors", () => {
        it("throws when key hash not in map", async () => {
            const plain = Buffer.from("secret");
            const encrypted = await encryptBuffer(keyPair.publicKey, plain);
            const emptyMap: Record<string, import("node:crypto").KeyObject> = {};
            await expect(decryptBuffer(encrypted, emptyMap)).rejects.toThrow(/No private key in map/);
        });

        it("throws when legacy data and no default key", async () => {
            const plain = Buffer.from("x");
            const encrypted = await encryptBuffer(keyPair.publicKey, plain);
            const legacyPayload = encrypted.slice(44);
            const noDefaultMap: Record<string, import("node:crypto").KeyObject> = {
                [hashPublicKey(keyPair.publicKey).toString("hex")]: keyPair.privateKey,
            };
            await expect(decryptBuffer(legacyPayload, noDefaultMap)).rejects.toThrow(/privateKeyMap\["default"\]/);
        });

        it("throws when data too short for tag", async () => {
            await expect(decryptBuffer(Buffer.alloc(2), keyMap)).rejects.toThrow(/too short/);
        });
    });
});
