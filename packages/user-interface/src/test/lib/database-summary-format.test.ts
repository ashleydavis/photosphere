import { formatBytes, getStorageType } from "../../lib/database-summary-format";

describe("database summary formatting", () => {

    describe("formatBytes", () => {

        test("names zero bytes rather than dividing by it", () => {
            expect(formatBytes(0)).toBe("0 Bytes");
        });

        test("leaves a value under a kibibyte in bytes", () => {
            expect(formatBytes(512)).toBe("512 Bytes");
        });

        test("steps up a unit at each boundary", () => {
            expect(formatBytes(1024)).toBe("1 KiB");
            expect(formatBytes(1024 * 1024)).toBe("1 MiB");
            expect(formatBytes(1024 * 1024 * 1024)).toBe("1 GiB");
            expect(formatBytes(1024 * 1024 * 1024 * 1024)).toBe("1 TiB");
        });

        test("keeps a fractional part below a hundred", () => {
            expect(formatBytes(1536)).toBe("1.5 KiB");
            expect(formatBytes(1024 * 1024 * 2.25)).toBe("2.25 MiB");
        });

        test("rounds to a whole number at or above a hundred in its unit", () => {
            expect(formatBytes(1024 * 100.4)).toBe("100 KiB");
            expect(formatBytes(1024 * 999.6)).toBe("1,000 KiB");
        });
    });

    describe("getStorageType", () => {

        test("names object storage for an s3 path", () => {
            expect(getStorageType("s3:my-bucket/photos")).toBe("S3-compatible object storage");
        });

        test("names the filesystem for a plain path", () => {
            expect(getStorageType("/home/user/photos")).toBe("Local filesystem");
        });
    });
});
