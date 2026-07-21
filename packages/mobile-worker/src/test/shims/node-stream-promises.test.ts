import { Buffer } from "buffer";
import { pipeline } from "../../shims/node-stream-promises";
import { Readable, Writable, Transform } from "../../shims/node-stream";

//
// Unit tests for the `stream/promises` shim. `pipeline` is what the asset server uses to pump a
// decrypted asset stream into the HTTP response, and what FileStorage.writeStream uses to write a
// readable into the whole-file writable.
//
describe("node-stream-promises pipeline shim", () => {

    test("pumps a readable's payload into a writable and resolves once it finishes", async () => {
        const payload = Buffer.from("pipeline payload", "utf8");
        const readable = new Readable(payload);

        let flushed: Buffer | undefined;
        const writable = new Writable((data: Buffer) => { flushed = data; });

        await pipeline(readable as any, writable as any);

        expect(flushed?.equals(payload)).toBe(true);
    });

    test("pumps a transform's output into a writable (the asset-serving shape)", async () => {
        const transform = new (Transform as any)({
            transform(chunk: Buffer, encoding: string, callback: () => void) {
                (this as any).push(Buffer.from(chunk.toString("utf8").toUpperCase(), "utf8"));
                callback();
            },
        });

        let flushed: Buffer | undefined;
        const writable = new Writable((data: Buffer) => { flushed = data; });

        const finished = pipeline(transform, writable as any);
        transform.write(Buffer.from("served", "utf8"));
        transform.end();

        await finished;
        expect(flushed?.toString("utf8")).toBe("SERVED");
    });

    test("rejects when the source emits an error", async () => {
        const failure = new Error("source blew up");
        const source: any = {
            on(eventName: string, listener: (arg?: unknown) => void) {
                if (eventName === "error") {
                    // Report the failure once the caller has attached its handlers.
                    Promise.resolve().then(() => listener(failure));
                }
            },
        };
        const destination: any = {
            on() { /* never finishes */ },
            write() { return true; },
            end() { /* not reached */ },
        };

        await expect(pipeline(source, destination)).rejects.toThrow("source blew up");
    });

    test("rejects when the destination emits an error", async () => {
        const failure = new Error("destination blew up");
        const source: any = {
            on() { /* no source events */ },
        };
        const destination: any = {
            on(eventName: string, listener: (arg?: unknown) => void) {
                if (eventName === "error") {
                    Promise.resolve().then(() => listener(failure));
                }
            },
            write() { return true; },
            end() { /* not reached */ },
        };

        await expect(pipeline(source, destination)).rejects.toThrow("destination blew up");
    });
});
