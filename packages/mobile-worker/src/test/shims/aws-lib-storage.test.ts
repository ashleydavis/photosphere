import { Buffer } from "buffer";
import { Upload } from "../../shims/aws-lib-storage";
import { Readable } from "../../shims/node-stream";

//
// Builds a mock S3 client that records the commands sent through it.
//
function createMockClient() {
    const send = jest.fn().mockResolvedValue(undefined);
    return { client: { send } as any, send };
}

//
// Unit tests for the `@aws-sdk/lib-storage` shim. CloudStorage uploads through `Upload`, which the
// mobile worker implements as a single PutObject rather than a multipart upload.
//
describe("aws-lib-storage Upload shim", () => {

    test("uploads a Buffer body as a single PutObject", async () => {
        const { client, send } = createMockClient();
        const body = Buffer.from("buffer body", "utf8");

        await new Upload({
            client,
            params: { Bucket: "the-bucket", Key: "the/key", Body: body, ContentType: "text/plain" },
        }).done();

        expect(send).toHaveBeenCalledTimes(1);
        const command = send.mock.calls[0][0];
        expect(command.commandName).toBe("PutObject");
        expect(command.input.Bucket).toBe("the-bucket");
        expect(command.input.Key).toBe("the/key");
        expect(command.input.ContentType).toBe("text/plain");
        expect(command.input.Body.equals(body)).toBe(true);
    });

    test("sets ContentLength from the buffered body rather than the caller's value", async () => {
        const { client, send } = createMockClient();
        const body = Buffer.from("12345", "utf8");

        await new Upload({
            client,
            params: { Bucket: "b", Key: "k", Body: body, ContentLength: 9999 },
        }).done();

        expect(send.mock.calls[0][0].input.ContentLength).toBe(5);
    });

    test("converts a Uint8Array body to a Buffer", async () => {
        const { client, send } = createMockClient();
        const body = new Uint8Array([1, 2, 3, 4]);

        await new Upload({
            client,
            params: { Bucket: "b", Key: "k", Body: body },
        }).done();

        const uploaded = send.mock.calls[0][0].input.Body;
        expect(Buffer.isBuffer(uploaded)).toBe(true);
        expect(Array.from(uploaded as Buffer)).toEqual([1, 2, 3, 4]);
    });

    test("collects a stream body into a single buffer before uploading", async () => {
        const { client, send } = createMockClient();
        const payload = Buffer.from("streamed body", "utf8");

        await new Upload({
            client,
            params: { Bucket: "b", Key: "k", Body: new Readable(payload) as any },
        }).done();

        expect(send.mock.calls[0][0].input.Body.equals(payload)).toBe(true);
        expect(send.mock.calls[0][0].input.ContentLength).toBe(payload.length);
    });

    test("rejects when the stream body emits an error", async () => {
        const { client, send } = createMockClient();
        const failure = new Error("body stream failed");
        const body: any = {
            on(eventName: string, listener: (arg?: unknown) => void) {
                if (eventName === "error") {
                    Promise.resolve().then(() => listener(failure));
                }
            },
        };

        await expect(new Upload({
            client,
            params: { Bucket: "b", Key: "k", Body: body },
        }).done()).rejects.toThrow("body stream failed");

        expect(send).not.toHaveBeenCalled();
    });

    test("does not upload anything until done() is called", () => {
        const { client, send } = createMockClient();

        new Upload({
            client,
            params: { Bucket: "b", Key: "k", Body: Buffer.from("x") },
        });

        expect(send).not.toHaveBeenCalled();
    });
});
