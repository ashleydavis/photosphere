import { MockStorage } from "./mock-storage";
import { readEncryptionHeader } from "../lib/read-encryption-header";
import { ENCRYPTION_TAG, NEW_FORMAT_HEADER_LENGTH, PUBLIC_KEY_HASH_LENGTH } from "../lib/encryption-constants";

describe("readEncryptionHeader", () => {
    const filePath = "some/file.dat";

    it("returns undefined when file does not exist", async () => {
        const storage = new MockStorage();
        expect(await readEncryptionHeader(storage, filePath)).toBeUndefined();
    });

    it("returns undefined when file is empty", async () => {
        const storage = new MockStorage();
        await storage.write(filePath, undefined, Buffer.alloc(0));
        expect(await readEncryptionHeader(storage, filePath)).toBeUndefined();
    });

    it("returns undefined when file has fewer than 4 bytes", async () => {
        const storage = new MockStorage();
        await storage.write(filePath, undefined, Buffer.from("PSE"));
        expect(await readEncryptionHeader(storage, filePath)).toBeUndefined();
    });

    it("returns undefined when file does not start with encryption tag", async () => {
        const storage = new MockStorage();
        const buf = Buffer.alloc(NEW_FORMAT_HEADER_LENGTH);
        buf.write("XXXX", 0, 4, "ascii");
        await storage.write(filePath, undefined, buf);
        expect(await readEncryptionHeader(storage, filePath)).toBeUndefined();
    });

    it("returns undefined when file has correct tag but length less than header length", async () => {
        const storage = new MockStorage();
        const buf = Buffer.alloc(20);
        buf.write(ENCRYPTION_TAG, 0, 4, "ascii");
        await storage.write(filePath, undefined, buf);
        expect(await readEncryptionHeader(storage, filePath)).toBeUndefined();
    });

    it("returns key hash buffer when file has valid new-format header", async () => {
        const storage = new MockStorage();
        const keyHash = Buffer.alloc(PUBLIC_KEY_HASH_LENGTH, 0xab);
        const header = Buffer.alloc(NEW_FORMAT_HEADER_LENGTH);
        header.write(ENCRYPTION_TAG, 0, 4, "ascii");
        keyHash.copy(header, 12);
        await storage.write(filePath, undefined, header);

        const result = await readEncryptionHeader(storage, filePath);
        expect(result).toBeDefined();
        expect(Buffer.isBuffer(result)).toBe(true);
        expect(result!.length).toBe(PUBLIC_KEY_HASH_LENGTH);
        expect(result!.equals(keyHash)).toBe(true);
    });

    it("returns key hash when file is longer than header", async () => {
        const storage = new MockStorage();
        const keyHash = Buffer.alloc(PUBLIC_KEY_HASH_LENGTH, 0xcd);
        const fullFile = Buffer.alloc(NEW_FORMAT_HEADER_LENGTH + 100);
        fullFile.write(ENCRYPTION_TAG, 0, 4, "ascii");
        keyHash.copy(fullFile, 12);
        await storage.write(filePath, undefined, fullFile);

        const result = await readEncryptionHeader(storage, filePath);
        expect(result).toBeDefined();
        expect(result!.length).toBe(PUBLIC_KEY_HASH_LENGTH);
        expect(result!.equals(keyHash)).toBe(true);
    });
});
