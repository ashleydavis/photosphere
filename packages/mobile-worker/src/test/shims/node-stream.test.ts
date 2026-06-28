import { Readable, Writable, Duplex, Transform, PassThrough } from "../../shims/node-stream";

//
// Unit tests for the minimal Readable used by createReadStream and serialization.loadVersion.
//
describe("node-stream Readable shim", () => {

    test("emits the payload as a single data event then end", async () => {
        const payload = Buffer.from("stream payload", "utf8");
        const readable = new Readable(payload);

        const received: Buffer[] = [];
        await new Promise<void>((resolveDone) => {
            readable.on("data", (chunk: Buffer) => {
                received.push(chunk);
            });
            readable.on("end", () => {
                resolveDone();
            });
        });

        expect(received.length).toBe(1);
        expect(received[0].equals(payload)).toBe(true);
    });

    test("destroy() before the microtask runs suppresses both data and end", async () => {
        const readable = new Readable(Buffer.from("ignored", "utf8"));

        let sawData = false;
        let sawEnd = false;
        readable.on("data", () => {
            sawData = true;
        });
        readable.on("end", () => {
            sawEnd = true;
        });
        readable.destroy();

        // Let the scheduled microtask run.
        await Promise.resolve();
        await Promise.resolve();

        expect(sawData).toBe(false);
        expect(sawEnd).toBe(false);
    });

    test("once is an alias for on", async () => {
        const payload = Buffer.from("abc", "utf8");
        const readable = new Readable(payload);
        const result = await new Promise<Buffer>((resolveData) => {
            readable.once("data", (chunk: Buffer) => resolveData(chunk));
        });
        expect(result.equals(payload)).toBe(true);
    });

    test("Writable buffers chunks and flushes the full buffer on end()", () => {
        let flushed: Buffer | undefined;
        const writable = new Writable((data: Buffer) => { flushed = data; });
        let finished = false;
        writable.on("finish", () => { finished = true; });
        writable.write(Buffer.from("ab"));
        writable.end(Buffer.from("c"));
        expect(flushed?.toString("utf8")).toBe("abc");
        expect(finished).toBe(true);
    });

    test("Duplex/Transform/PassThrough are ES5-style bases (constructible and callable via .call)", () => {
        // Constructible with `new`.
        expect(new (Duplex as any)()).toBeDefined();
        expect(new (Transform as any)()).toBeDefined();
        expect(new (PassThrough as any)()).toBeDefined();
        // Callable as `Base.call(this)` (the cipher-base / create-hash inheritance pattern) without
        // the "class constructors must be invoked with 'new'" error an ES6 class would throw.
        const target: any = {};
        expect(() => (Transform as any).call(target)).not.toThrow();
    });
});
