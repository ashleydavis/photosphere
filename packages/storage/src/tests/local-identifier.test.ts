import { getLocalIdentifier } from "../lib/local-identifier";

describe("getLocalIdentifier", () => {
    describe("File system storage", () => {
        test("should handle Unix-style paths", () => {
            expect(getLocalIdentifier("fs:/home/user/photos")).toBe("fs/home/user/photos");
            expect(getLocalIdentifier("fs:/var/lib/db")).toBe("fs/var/lib/db");
            expect(getLocalIdentifier("fs:/")).toBe("fs/");
        });

        test("should handle Windows-style paths", () => {
            expect(getLocalIdentifier("fs:C:\\Users\\John\\Photos")).toBe("fs/c/users/john/photos");
            expect(getLocalIdentifier("fs:D:\\Data\\Database")).toBe("fs/d/data/database");
            expect(getLocalIdentifier("fs:E:\\")).toBe("fs/e/");
        });

        test("should handle mixed path separators", () => {
            expect(getLocalIdentifier("fs:C:/Users/John\\Photos")).toBe("fs/c/users/john/photos");
            expect(getLocalIdentifier("fs:/home\\user/data")).toBe("fs/home/user/data");
        });

        test("should handle multiple leading slashes", () => {
            expect(getLocalIdentifier("fs:///home/user/data")).toBe("fs/home/user/data");
            expect(getLocalIdentifier("fs://var//lib///db")).toBe("fs/var//lib///db");
        });

        test("should handle relative paths", () => {
            expect(getLocalIdentifier("fs:./my-db")).toBe("fs/./my-db");
            expect(getLocalIdentifier("fs:../parent/db")).toBe("fs/../parent/db");
        });
    });

    describe("S3 storage", () => {
        test("should handle basic S3 paths", () => {
            expect(getLocalIdentifier("s3:my-bucket:/photos/db")).toBe("s3/my-bucket/photos/db");
            expect(getLocalIdentifier("s3:bucket-name:/data")).toBe("s3/bucket-name/data");
            expect(getLocalIdentifier("s3:test:/")).toBe("s3/test/");
        });

        test("should handle S3 paths without leading slash", () => {
            expect(getLocalIdentifier("s3:my-bucket:photos/db")).toBe("s3/my-bucket/photos/db");
            expect(getLocalIdentifier("s3:bucket-name:data")).toBe("s3/bucket-name/data");
        });

        test("should handle S3 paths with multiple leading slashes", () => {
            expect(getLocalIdentifier("s3:my-bucket:///photos/db")).toBe("s3/my-bucket/photos/db");
            expect(getLocalIdentifier("s3:bucket-name://data")).toBe("s3/bucket-name/data");
        });

        test("should handle bucket-only S3 paths", () => {
            expect(getLocalIdentifier("s3:my-bucket")).toBe("s3/my-bucket");
            expect(getLocalIdentifier("s3:bucket-name-123")).toBe("s3/bucket-name-123");
        });

        test("should handle S3 paths with dots and dashes", () => {
            expect(getLocalIdentifier("s3:my-bucket.example.com:/path/to/db")).toBe("s3/my-bucket.example.com/path/to/db");
            expect(getLocalIdentifier("s3:bucket-with-dashes:/data-folder")).toBe("s3/bucket-with-dashes/data-folder");
        });
    });

    describe("Other storage types", () => {
        test("should handle generic storage URLs", () => {
            expect(getLocalIdentifier("memory://test")).toBe("memory/test");
            expect(getLocalIdentifier("ftp://server/path")).toBe("ftp/server/path");
            expect(getLocalIdentifier("http://example.com/api")).toBe("http/example.com/api");
        });

        test("should handle paths without scheme (defaults to fs:)", () => {
            expect(getLocalIdentifier("/home/user/db")).toBe("fs/home/user/db");
            expect(getLocalIdentifier("C:\\Users\\Data")).toBe("fs/c/users/data");
            expect(getLocalIdentifier("relative/path")).toBe("fs/relative/path");
        });

        test("should handle complex URLs", () => {
            expect(getLocalIdentifier("redis://localhost:6379/db")).toBe("redis/localhost/6379/db");
            expect(getLocalIdentifier("mongodb://user:pass@host:27017/db")).toBe("mongodb/user/pass@host/27017/db");
        });
    });

    describe("Edge cases", () => {
        test("should throw on empty strings", () => {
            expect(() => getLocalIdentifier("")).toThrow("Storage location cannot be empty");
            expect(() => getLocalIdentifier("fs:")).toThrow("Empty path after fs: scheme");
            expect(() => getLocalIdentifier("s3:")).toThrow("Empty path after s3: scheme");
        });

        test("should handle case sensitivity", () => {
            expect(getLocalIdentifier("fs:/HOME/USER/DB")).toBe("fs/home/user/db");
            expect(getLocalIdentifier("S3:MY-BUCKET:/DATA")).toBe("s3/my-bucket/data");
            expect(getLocalIdentifier("REDIS://LOCALHOST")).toBe("redis/localhost");
        });

        test("should handle special characters", () => {
            expect(getLocalIdentifier("fs:/home/user with spaces/db")).toBe("fs/home/user with spaces/db");
            expect(getLocalIdentifier("s3:bucket-123:/path/with spaces")).toBe("s3/bucket-123/path/with spaces");
        });
    });
});