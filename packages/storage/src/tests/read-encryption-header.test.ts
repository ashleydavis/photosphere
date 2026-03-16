import { MockStorage } from "./mock-storage";
import { readEncryptionHeader, readFirstBytes } from "../lib/read-encryption-header";
import { ENCRYPTION_TAG, NEW_FORMAT_HEADER_LENGTH, PUBLIC_KEY_HASH_LENGTH } from "../lib/encryption-constants";

describe("readFirstBytes", () => {
    const filePath = "some/file.dat";

    it("returns undefined when file does not exist", async () => {
        const storage = new MockStorage();
        expect(await readFirstBytes(storage, filePath, 10)).toBeUndefined();
    });

    it("returns undefined when file is empty", async () => {
        const storage = new MockStorage();
        await storage.write(filePath, undefined, Buffer.alloc(0));
        expect(await readFirstBytes(storage, filePath, 10)).toBeUndefined();
    });

    it("returns full buffer when file is shorter than requested length", async () => {
        const storage = new MockStorage();
        const data = Buffer.from([1, 2, 3]);
        await storage.write(filePath, undefined, data);
        const result = await readFirstBytes(storage, filePath, 10);
        expect(result).toBeDefined();
        expect(result!.equals(data)).toBe(true);
    });

    it("returns exactly length bytes when file is larger than requested length", async () => {
        const storage = new MockStorage();
        const data = Buffer.alloc(1000, 0xab);
        await storage.write(filePath, undefined, data);
        const result = await readFirstBytes(storage, filePath, 10);
        expect(result).toBeDefined();
        expect(result!.length).toBe(10);
        expect(result!.equals(data.subarray(0, 10))).toBe(true);
    });

    it("returns exactly length bytes for a large file", async () => {
        const storage = new MockStorage();
        const data = Buffer.alloc(10_000, 0xcd);
        await storage.write(filePath, undefined, data);
        const result = await readFirstBytes(storage, filePath, NEW_FORMAT_HEADER_LENGTH);
        expect(result).toBeDefined();
        expect(result!.length).toBe(NEW_FORMAT_HEADER_LENGTH);
        expect(result!.equals(data.subarray(0, NEW_FORMAT_HEADER_LENGTH))).toBe(true);
    });
});

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
