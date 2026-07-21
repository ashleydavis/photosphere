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

    test("pipe forwards the payload into a destination and ends it", async () => {
        const payload = Buffer.from("piped payload", "utf8");
        const readable = new Readable(payload);

        let flushed: Buffer | undefined;
        const destination = new Writable((data: Buffer) => { flushed = data; });

        const finished = new Promise<void>((resolveDone) => {
            destination.on("finish", () => resolveDone());
        });

        expect(readable.pipe(destination)).toBe(destination);

        await finished;
        expect(flushed?.equals(payload)).toBe(true);
    });
});

//
// Unit tests for the Transform used by the encryption layer's decryption stream, which the asset
// server pipes an encrypted file read through when serving an asset.
//
describe("node-stream Transform shim", () => {

    //
    // Builds a Transform that uppercases each chunk and appends a marker when the input ends, so
    // both the transform and flush hooks are observable.
    //
    function createUppercaseTransform(): any {
        return new (Transform as any)({
            transform(chunk: Buffer, encoding: string, callback: () => void) {
                (this as any).push(Buffer.from(chunk.toString("utf8").toUpperCase(), "utf8"));
                callback();
            },
            flush(callback: () => void) {
                (this as any).push(Buffer.from("!", "utf8"));
                callback();
            },
        });
    }

    //
    // Collects the transform's output, resolving once it ends.
    //
    function collectOutput(transform: any): Promise<string> {
        const received: Buffer[] = [];
        return new Promise<string>((resolveDone) => {
            transform.on("data", (chunk: Buffer) => {
                received.push(chunk);
            });
            transform.on("end", () => {
                resolveDone(Buffer.concat(received).toString("utf8"));
            });
        });
    }

    test("runs the transform hook per write and the flush hook on end", async () => {
        const transform = createUppercaseTransform();
        const output = collectOutput(transform);

        transform.write(Buffer.from("ab", "utf8"));
        transform.end();

        expect(await output).toBe("AB!");
    });

    test("buffers output produced before a data listener attaches", async () => {
        const transform = createUppercaseTransform();

        // Write and end before anything is listening: the source Readable emits on a microtask, so
        // output can be produced before the consumer is hooked up and must not be dropped.
        transform.write(Buffer.from("xy", "utf8"));
        transform.end();
        await Promise.resolve();
        await Promise.resolve();

        expect(await collectOutput(transform)).toBe("XY!");
    });

    test("passes chunks through unchanged when no transform hook is supplied", async () => {
        const transform = new (Transform as any)();
        const output = collectOutput(transform);

        transform.write(Buffer.from("hello", "utf8"));
        transform.end();

        expect(await output).toBe("hello");
    });

    test("pipe forwards transformed output into a destination and ends it", async () => {
        const transform = createUppercaseTransform();

        let flushed: Buffer | undefined;
        const destination = new Writable((data: Buffer) => { flushed = data; });
        const finished = new Promise<void>((resolveDone) => {
            destination.on("finish", () => resolveDone());
        });

        expect(transform.pipe(destination)).toBe(destination);
        transform.write(Buffer.from("ok", "utf8"));
        transform.end();

        await finished;
        expect(flushed?.toString("utf8")).toBe("OK!");
    });

    test("destroy suppresses any further output", async () => {
        const transform = createUppercaseTransform();

        let sawData = false;
        let sawEnd = false;
        transform.on("data", () => { sawData = true; });
        transform.on("end", () => { sawEnd = true; });

        transform.write(Buffer.from("ab", "utf8"));
        transform.destroy();

        // Let the scheduled drain microtask run.
        await Promise.resolve();
        await Promise.resolve();

        expect(sawData).toBe(false);
        expect(sawEnd).toBe(false);
    });

});
