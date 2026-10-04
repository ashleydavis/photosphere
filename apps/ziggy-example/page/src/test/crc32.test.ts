import { crc32 } from "../lib/crc32";

describe("crc32", () => {
    test("matches the standard check value", () => {
        expect(crc32("123456789")).toBe(0xCBF43926);
    });

    test("is zero for empty text", () => {
        expect(crc32("")).toBe(0);
    });

    test("hashes the UTF-8 bytes of non-ASCII text", () => {
        // The value zlib's crc32 gives for the UTF-8 bytes of this text.
        expect(crc32("é世界😀")).toBe(691409432);
    });
});
