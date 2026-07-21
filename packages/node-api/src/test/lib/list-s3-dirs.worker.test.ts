import { parseS3Credentials } from "../../lib/list-s3-dirs.worker";

describe("parseS3Credentials", () => {

    test("parses the full S3 credentials JSON into the CloudStorage shape", () => {
        const value = JSON.stringify({
            accessKeyId: "AKIA123",
            secretAccessKey: "secret456",
            region: "ap-southeast-2",
            endpoint: "https://minio.example:9000",
        });
        expect(parseS3Credentials(value)).toEqual({
            accessKeyId: "AKIA123",
            secretAccessKey: "secret456",
            region: "ap-southeast-2",
            endpoint: "https://minio.example:9000",
        });
    });

    test("leaves optional region/endpoint undefined when absent", () => {
        const value = JSON.stringify({ accessKeyId: "AKIA123", secretAccessKey: "secret456" });
        const parsed = parseS3Credentials(value);
        expect(parsed.accessKeyId).toBe("AKIA123");
        expect(parsed.secretAccessKey).toBe("secret456");
        expect(parsed.region).toBeUndefined();
        expect(parsed.endpoint).toBeUndefined();
    });
});
