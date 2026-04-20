import { Readable } from "stream";
import { computeEncryptedLength, createEncryptionStream, createDecryptionStream } from "../lib/encrypt-stream";
import { generateKeyPair, hashPublicKey } from "../lib/key-utils";
import { encryptBuffer } from "../lib/encrypt-buffer";
import { ENCRYPTION_TAG } from "../lib/encryption-constants";

function streamToBuffer(stream: NodeJS.ReadableStream): Promise<Buffer> {
    const chunks: Buffer[] = [];
    return new Promise((resolve, reject) => {
        stream.on("data", (chunk: Buffer) => chunks.push(chunk));
        stream.on("end", () => resolve(Buffer.concat(chunks)));
        stream.on("error", reject);
    });
}

describe("computeEncryptedLength", () => {
    const keyPair = generateKeyPair();

    test("returns correct length for empty input", () => {
        expect(computeEncryptedLength(0)).toBe(588); // 572 overhead + 16 (one padding block)
    });

    test("returns correct length for non-block-aligned input", () => {
        expect(computeEncryptedLength(1)).toBe(588);   // 572 + 16
        expect(computeEncryptedLength(15)).toBe(588);  // 572 + 16
        expect(computeEncryptedLength(17)).toBe(604);  // 572 + 32
    });

    test("returns correct length for block-aligned input", () => {
        expect(computeEncryptedLength(16)).toBe(604);  // 572 + 32 (full padding block added)
        expect(computeEncryptedLength(32)).toBe(620);  // 572 + 48
    });

    test("matches actual encrypted stream output length", async () => {
        for (const plainLength of [0, 1, 15, 16, 17, 32, 100]) {
            const plain = Buffer.alloc(plainLength, 0x42);
            const enc = createEncryptionStream(keyPair.publicKey);
            Readable.from(plain).pipe(enc);
            const encryptedBuffer = await streamToBuffer(enc);
            expect(encryptedBuffer.length).toBe(computeEncryptedLength(plainLength));
        }
    });
});

describe("encrypt-stream", () => {
    const keyPair = generateKeyPair();
    const keyMap: Record<string, import("node:crypto").KeyObject> = {
        default: keyPair.privateKey,
        [hashPublicKey(keyPair.publicKey).toString("hex")]: keyPair.privateKey,
    };

    describe("new format round-trip", () => {
        it("encrypts and decrypts stream with key map", async () => {
            const plain = Buffer.from("hello stream world");
            const enc = createEncryptionStream(keyPair.publicKey);
            const dec = createDecryptionStream(keyMap);
            Readable.from(plain).pipe(enc).pipe(dec);
            const out = await streamToBuffer(dec);
            expect(out.equals(plain)).toBe(true);
        });

        it("stream output starts with new-format header", async () => {
            const plain = Buffer.from("x");
            const enc = createEncryptionStream(keyPair.publicKey);
            const chunks: Buffer[] = [];
            enc.on("data", (chunk: Buffer) => chunks.push(chunk));
            await new Promise<void>((resolve, reject) => {
                Readable.from(plain).pipe(enc);
                enc.on("end", resolve);
                enc.on("error", reject);
            });
            const first = chunks[0];
            expect(first.length).toBeGreaterThanOrEqual(4);
            expect(first.slice(0, 4).toString("ascii")).toBe(ENCRYPTION_TAG);
        });
    });

    describe("legacy format (no header)", () => {
        it("decrypts legacy payload using default key", async () => {
            const plain = Buffer.from("legacy stream payload");
            const fullEncrypted = encryptBuffer(keyPair.publicKey, plain);
            const legacyPayload = fullEncrypted.slice(44);
            const dec = createDecryptionStream(keyMap);
            Readable.from(legacyPayload).pipe(dec);
            const out = await streamToBuffer(dec);
            expect(out.equals(plain)).toBe(true);
        });
    });

    describe("new format with key hash lookup", () => {
        it("decrypts new-format stream using hash key in map", async () => {
            const plain = Buffer.from("new format stream");
            const enc = createEncryptionStream(keyPair.publicKey);
            const dec = createDecryptionStream(keyMap);
            Readable.from(plain).pipe(enc).pipe(dec);
            const out = await streamToBuffer(dec);
            expect(out.equals(plain)).toBe(true);
        });

        it("decrypts buffer-encrypted new format with stream", async () => {
            const plain = Buffer.from("buffer then stream");
            const encrypted = encryptBuffer(keyPair.publicKey, plain);
            const dec = createDecryptionStream(keyMap);
            Readable.from(encrypted).pipe(dec);
            const out = await streamToBuffer(dec);
            expect(out.equals(plain)).toBe(true);
        });
    });

    describe("pass-through (no decryption)", () => {
        it("passes plain data through when key map has no default key", async () => {
            const plain = Buffer.from("plain file content");
            const dec = createDecryptionStream({});
            Readable.from(plain).pipe(dec);
            const out = await streamToBuffer(dec);
            expect(out.equals(plain)).toBe(true);
        });

        it("passes data through when new-format header present but no matching key in map", async () => {
            const encrypted = encryptBuffer(keyPair.publicKey, Buffer.from("secret"));
            const dec = createDecryptionStream({});
            Readable.from(encrypted).pipe(dec);
            const out = await streamToBuffer(dec);
            expect(out.equals(encrypted)).toBe(true);
        });

        it("passes plain data through when default key present but data is not encrypted (legacy decrypt throws)", async () => {
            const plain = Buffer.from("plain file content that is not encrypted");
            const dec = createDecryptionStream(keyMap);
            Readable.from(plain).pipe(dec);
            const out = await streamToBuffer(dec);
            expect(out.equals(plain)).toBe(true);
        });
    });
});
