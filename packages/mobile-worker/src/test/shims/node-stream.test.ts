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

    test("Transform is an ES5-style base, so cipher-base can inherit from it via .call", () => {
        expect(new (Transform as any)()).toBeDefined();
        // Callable as `Base.call(this)` (the cipher-base / create-hash inheritance pattern) without
        // the "class constructors must be invoked with 'new'" error an ES6 class would throw.
        const target: any = {};
        expect(() => (Transform as any).call(target)).not.toThrow();
    });

    test("Duplex and PassThrough are constructible", () => {
        expect(new (Duplex as any)()).toBeDefined();
        expect(new (PassThrough as any)()).toBeDefined();
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
// Unit tests for the push-driven Readable: a subclass implements _read() and delivers bytes with
// push(), ending with push(null). This is the shape S3RangeReadableStream uses to fetch an object in
// ranges, so it is the path every read from S3 on a device takes.
//
// Before this was implemented, push() went nowhere and the stream emitted its (absent) fixed payload
// instead, so consumers received a single `undefined` chunk. That is what made reading anything out
// of S3 on a device fail inside the first code that looked at the bytes.
//
describe("node-stream Readable shim, push-driven", () => {

    //
    // Collects everything a stream emits, resolving with the chunks once it ends.
    //
    function collect(readable: Readable): Promise<Buffer[]> {
        return new Promise<Buffer[]>((resolveDone, rejectDone) => {
            const received: Buffer[] = [];
            readable.on("data", (chunk: Buffer) => {
                received.push(chunk);
            });
            readable.on("end", () => {
                resolveDone(received);
            });
            readable.on("error", (err: Error) => {
                rejectDone(err);
            });
        });
    }

    //
    // A stream that pushes the given chunks one per _read() call, then ends. `synchronous` controls
    // whether each push happens inside the _read() call or on a later microtask, because those are
    // different paths through the pump: one recurses, the other resumes from push().
    //
    class ChunkedReadable extends Readable {
        private nextIndex = 0;

        constructor(private readonly chunks: Buffer[], private readonly synchronous: boolean) {
            super();
        }

        protected _read(): void {
            const deliver = () => {
                if (this.nextIndex >= this.chunks.length) {
                    this.push(null);
                    return;
                }
                const chunk = this.chunks[this.nextIndex];
                this.nextIndex += 1;
                this.push(chunk);
            };

            if (this.synchronous) {
                deliver();
            }
            else {
                Promise.resolve().then(deliver);
            }
        }
    }

    test("delivers chunks pushed asynchronously from _read, in order, then ends", async () => {
        const chunks = [Buffer.from("one"), Buffer.from("two"), Buffer.from("three")];

        const received = await collect(new ChunkedReadable(chunks, false));

        expect(received.length).toBe(3);
        expect(Buffer.concat(received).toString()).toBe("onetwothree");
    });

    test("delivers chunks pushed synchronously from _read, in order, then ends", async () => {
        const chunks = [Buffer.from("alpha"), Buffer.from("beta")];

        const received = await collect(new ChunkedReadable(chunks, true));

        expect(received.length).toBe(2);
        expect(Buffer.concat(received).toString()).toBe("alphabeta");
    });

    test("never emits an undefined chunk", async () => {
        const received = await collect(new ChunkedReadable([Buffer.from("bytes")], false));

        for (const chunk of received) {
            expect(chunk).toBeDefined();
            expect(Buffer.isBuffer(chunk)).toBe(true);
        }
    });

    test("a stream that ends without pushing anything emits end and no data", async () => {
        const received = await collect(new ChunkedReadable([], false));

        expect(received).toEqual([]);
    });

    test("chunks pushed before a consumer attaches are still delivered", async () => {
        const readable = new Readable();
        readable.push(Buffer.from("early"));
        readable.push(null);

        const received = await collect(readable);

        expect(Buffer.concat(received).toString()).toBe("early");
    });

    test("end is emitted once even when push(null) is followed by another pump", async () => {
        const readable = new Readable();
        let endCount = 0;
        readable.on("end", () => {
            endCount += 1;
        });
        readable.on("data", () => {
            // Attaching a data listener is what schedules emission.
        });

        readable.push(Buffer.from("only"));
        readable.push(null);
        await Promise.resolve();
        await Promise.resolve();
        readable.push(null);
        await Promise.resolve();

        expect(endCount).toBe(1);
    });

    test("destroy() stops delivery of chunks pushed afterwards", async () => {
        const readable = new Readable();
        const received: Buffer[] = [];
        readable.on("data", (chunk: Buffer) => {
            received.push(chunk);
        });

        readable.destroy();
        readable.push(Buffer.from("after destroy"));
        readable.push(null);
        await Promise.resolve();
        await Promise.resolve();

        expect(received).toEqual([]);
    });

    test("pipe forwards pushed chunks to the destination and ends it", async () => {
        const written: Buffer[] = [];
        let ended = false;
        const destination = {
            write: (chunk: Buffer) => {
                written.push(chunk);
                return true;
            },
            end: () => {
                ended = true;
            },
        };

        new ChunkedReadable([Buffer.from("piped ")," bytes"].map(part => Buffer.from(part)), false)
            .pipe(destination);

        // Let the scheduled emission and its pushes run.
        for (let tick = 0; tick < 10; tick += 1) {
            await Promise.resolve();
        }

        expect(Buffer.concat(written).toString()).toBe("piped  bytes");
        expect(ended).toBe(true);
    });

    test("destroy(error) emits the error so a failed producer reaches its consumer", async () => {
        const readable = new Readable();
        const failure = new Error("range request failed");

        let seen: Error | undefined;
        readable.on("error", (err: Error) => {
            seen = err;
        });
        readable.on("data", () => {
            // Attaching a data listener is what schedules emission.
        });

        readable.destroy(failure);

        expect(seen).toBe(failure);
    });

    test("destroy() with no error emits nothing", async () => {
        const readable = new Readable();
        let sawError = false;
        readable.on("error", () => {
            sawError = true;
        });
        readable.on("data", () => {
            // Attaching a data listener is what schedules emission.
        });

        readable.destroy();
        await Promise.resolve();

        expect(sawError).toBe(false);
    });

    test("for await yields pushed chunks in order", async () => {
        // @aws-sdk/lib-storage consumes an upload body with for-await, so a stream without an async
        // iterator fails every upload with "not a function".
        const chunks = [Buffer.from("first "), Buffer.from("second")];
        const received: Buffer[] = [];

        for await (const chunk of new ChunkedReadable(chunks, false)) {
            received.push(chunk);
        }

        expect(Buffer.concat(received).toString()).toBe("first second");
    });

    test("for await yields a fixed payload", async () => {
        const received: Buffer[] = [];

        for await (const chunk of new Readable(Buffer.from("payload"))) {
            received.push(chunk);
        }

        expect(Buffer.concat(received).toString()).toBe("payload");
    });

    test("for await rethrows a stream error", async () => {
        const readable = new Readable();
        const failure = new Error("stream broke");

        const iterate = async () => {
            for await (const _chunk of readable) {
                // Consuming; the error is what matters.
            }
        };

        const iterated = iterate();
        readable.destroy(failure);

        await expect(iterated).rejects.toThrow("stream broke");
    });

    test("a readable-shaped object counts as a Readable instance", () => {
        // The AWS SDK refuses to read a response body that is not `instanceof Readable`, and the http
        // shim's IncomingMessage is an independent event emitter rather than a subclass of this one.
        const readableShaped = {
            on: () => undefined,
            push: () => true,
            destroy: () => undefined,
        };

        expect(readableShaped instanceof Readable).toBe(true);
    });

    test("real instances and subclasses still count as Readable instances", () => {
        class Subclass extends Readable {
        }

        expect(new Readable(Buffer.from("x")) instanceof Readable).toBe(true);
        expect(new Subclass() instanceof Readable).toBe(true);
    });

    test("objects that are not readable-shaped are not Readable instances", () => {
        expect({} instanceof Readable).toBe(false);
        expect({ on: () => undefined } instanceof Readable).toBe(false);
        expect((null as any) instanceof Readable).toBe(false);
        expect(("a string" as any) instanceof Readable).toBe(false);
    });

    test("a fixed-payload Readable is unaffected by the push-driven path", async () => {
        const payload = Buffer.from("fixed payload", "utf8");

        const received = await collect(new Readable(payload));

        expect(received.length).toBe(1);
        expect(received[0].equals(payload)).toBe(true);
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

//
// Unit tests for the Duplex the AWS SDK's ChecksumStream extends. Every S3 read runs through it: the
// response body is written into it, verified, and read back out by the SDK's collector.
//
describe("node-stream Duplex shim", () => {

    //
    // A Duplex subclass shaped like the AWS SDK's ChecksumStream: it takes bytes on the writable side
    // through _write, republishes them to the readable side, and finishes through _final.
    //
    class PassThroughDuplex extends Duplex {
        // Chunks seen by the writable side, so a test can assert what was written.
        readonly written: Buffer[] = [];

        // Receives a written chunk and forwards it to the readable side.
        _write(chunk: Buffer, encoding: string, callback: (error?: Error) => void): void {
            this.written.push(chunk);
            this.push(chunk);
            callback();
        }

        // Ends the writable side.
        _final(callback: (error?: Error) => void): void {
            callback();
        }
    }

    //
    // Awaits enough microtasks for the deferred flush to run.
    //
    async function flush(): Promise<void> {
        for (let index = 0; index < 5; index++) {
            await Promise.resolve();
        }
    }

    test("is an instance of Readable, which is how the AWS SDK picks its Node code path", () => {
        expect(new PassThroughDuplex()).toBeInstanceOf(Readable);
    });

    test("routes written chunks through the _write hook", async () => {
        const duplex = new PassThroughDuplex();

        duplex.write(Buffer.from("payload"));

        expect(duplex.written.map(chunk => chunk.toString())).toEqual(["payload"]);
    });

    test("buffers pushed bytes until a consumer reads, so a late reader still gets them", async () => {
        const duplex = new PassThroughDuplex();

        // Everything is written and ended BEFORE any listener attaches, which is the order the AWS SDK
        // uses: its checksum stream consumes the whole response before the collector is piped on.
        duplex.write(Buffer.from("hello "));
        duplex.write(Buffer.from("world"));
        duplex.end();

        const received: Buffer[] = [];
        let ended = false;
        duplex.on("data", (chunk: Buffer) => received.push(chunk));
        duplex.on("end", () => { ended = true; });
        await flush();

        expect(Buffer.concat(received).toString()).toBe("hello world");
        expect(ended).toBe(true);
    });

    test("emits data then end in order for a reader attached up front", async () => {
        const duplex = new PassThroughDuplex();
        const events: string[] = [];
        duplex.on("data", () => events.push("data"));
        duplex.on("end", () => events.push("end"));

        duplex.write(Buffer.from("one"));
        await flush();
        duplex.end();
        await flush();

        expect(events).toEqual(["data", "end"]);
    });

    test("end runs the _final hook before ending the readable side", async () => {
        const order: string[] = [];
        class FinalOrderDuplex extends Duplex {
            // Records that the flush hook ran.
            _final(callback: (error?: Error) => void): void {
                order.push("final");
                callback();
            }
        }
        const duplex = new FinalOrderDuplex();
        // A `data` listener is what starts the stream flowing, as in Node; an `end` listener alone
        // leaves it paused and nothing is delivered.
        duplex.on("data", () => { /* consuming is what lets `end` fire */ });
        duplex.on("end", () => order.push("end"));

        duplex.end();
        await flush();

        expect(order).toEqual(["final", "end"]);
    });

    test("a _final error is emitted as an error rather than ending the stream", async () => {
        class FailingFinalDuplex extends Duplex {
            // Reports a flush failure, as a checksum mismatch does.
            _final(callback: (error?: Error) => void): void {
                callback(new Error("checksum mismatch"));
            }
        }
        const duplex = new FailingFinalDuplex();
        let errorMessage = "";
        let ended = false;
        duplex.on("error", (error: Error) => { errorMessage = error.message; });
        duplex.on("end", () => { ended = true; });

        duplex.end();
        await flush();

        expect(errorMessage).toBe("checksum mismatch");
        expect(ended).toBe(false);
    });

    test("invokes listeners with `this` bound to the stream, as Node's EventEmitter does", async () => {
        const duplex = new PassThroughDuplex();
        let boundTo: any = undefined;
        duplex.on("data", function (this: any) { boundTo = this; });

        duplex.write(Buffer.from("x"));
        await flush();

        expect(boundTo).toBe(duplex);
    });
});

//
// Unit tests for the Writable hooks the AWS SDK's response collector relies on. The collector is a
// Writable subclass whose only body is `_write`; without the hook its buffer stays empty and every S3
// response reads as zero bytes.
//
describe("node-stream Writable shim hooks", () => {

    test("routes written chunks through a subclass's _write hook", () => {
        const collected: Buffer[] = [];
        class CollectingWritable extends Writable {
            // Gathers a written chunk, as the AWS SDK's collector does.
            _write(chunk: Buffer, encoding: string, callback: () => void): void {
                collected.push(chunk);
                callback();
            }
        }
        const writable = new CollectingWritable();

        writable.write(Buffer.from("part-one"));
        writable.write(Buffer.from("part-two"));

        expect(Buffer.concat(collected).toString()).toBe("part-onepart-two");
    });

    test("runs a subclass's _final hook before emitting finish", () => {
        const order: string[] = [];
        class FinalWritable extends Writable {
            // Records that the flush hook ran.
            _final(callback: () => void): void {
                order.push("final");
                callback();
            }
        }
        const writable = new FinalWritable();
        writable.on("finish", () => order.push("finish"));

        writable.end();

        expect(order).toEqual(["final", "finish"]);
    });

    test("invokes listeners with `this` bound to the stream, as Node's EventEmitter does", () => {
        const collected: Buffer[] = [];
        class CollectingWritable extends Writable {
            // The buffer the finish listener reads back off `this`.
            readonly bufferedBytes: Buffer[] = [];

            // Gathers a written chunk.
            _write(chunk: Buffer, encoding: string, callback: () => void): void {
                this.bufferedBytes.push(chunk);
                callback();
            }
        }
        const writable = new CollectingWritable();
        writable.on("finish", function (this: any) { collected.push(...this.bufferedBytes); });

        writable.write(Buffer.from("bound"));
        writable.end();

        expect(Buffer.concat(collected).toString()).toBe("bound");
    });

    test("still buffers to onFinish when the subclass supplies no hooks", () => {
        let flushed = "";
        const writable = new Writable(data => { flushed = data.toString(); });

        writable.write(Buffer.from("whole "));
        writable.end(Buffer.from("file"));

        expect(flushed).toBe("whole file");
    });
});

//
// Unit tests for the failure paths. A stream that swallows an error or drops bytes reports success for
// work that never happened, which is the failure mode that cost the most to track down here.
//
describe("node-stream shim failure reporting", () => {

    //
    // Awaits enough microtasks for the deferred flush to run.
    //
    async function flush(): Promise<void> {
        for (let index = 0; index < 5; index++) {
            await Promise.resolve();
        }
    }

    test("a Duplex error with no listener is thrown rather than dropped", () => {
        class FailingFinalDuplex extends Duplex {
            // Reports a flush failure, as a checksum mismatch does.
            _final(callback: (error?: Error) => void): void {
                callback(new Error("checksum mismatch"));
            }
        }
        const duplex = new FailingFinalDuplex();

        expect(() => duplex.end()).toThrow("checksum mismatch");
    });

    test("a Writable error with no listener is thrown rather than dropped", () => {
        const writable = new Writable(() => { throw new Error("disk full"); });
        writable.write(Buffer.from("bytes"));

        expect(() => writable.end()).toThrow("disk full");
    });

    test("writing to a Writable with no destination fails loudly instead of discarding the bytes", () => {
        const writable = new Writable(undefined as any);
        writable.write(Buffer.from("bytes that would vanish"));

        expect(() => writable.end()).toThrow(/no destination/);
    });

    test("an empty Writable with no destination still ends cleanly, since nothing is lost", () => {
        const writable = new Writable(undefined as any);
        let finished = false;
        writable.on("finish", () => { finished = true; });

        writable.end();

        expect(finished).toBe(true);
    });
});

//
// Unit tests for PassThrough. `@smithy/util-stream`'s splitStream builds one for every retryable
// upload body, so this is on the write path from the mobile worker to S3.
//
describe("node-stream PassThrough shim", () => {

    //
    // Awaits enough microtasks for the deferred flush to run.
    //
    async function flush(): Promise<void> {
        for (let index = 0; index < 5; index++) {
            await Promise.resolve();
        }
    }

    test("republishes written bytes to a reader", async () => {
        const passThrough = new PassThrough();
        const received: Buffer[] = [];
        passThrough.on("data", (chunk: Buffer) => received.push(chunk));

        passThrough.write(Buffer.from("upload "));
        passThrough.write(Buffer.from("body"));
        await flush();

        expect(Buffer.concat(received).toString()).toBe("upload body");
    });

    test("ends the readable side when the writable side ends", async () => {
        const passThrough = new PassThrough();
        let ended = false;
        passThrough.on("data", () => { /* consuming is what lets `end` fire */ });
        passThrough.on("end", () => { ended = true; });

        passThrough.end(Buffer.from("last"));
        await flush();

        expect(ended).toBe(true);
    });

    test("pipes into a destination, which is how splitStream feeds a request body", async () => {
        const passThrough = new PassThrough();
        const collected: Buffer[] = [];
        const destination = {
            write: (chunk: Buffer) => { collected.push(chunk); return true; },
            end: () => { /* nothing to flush */ },
        };

        passThrough.pipe(destination as any);
        passThrough.write(Buffer.from("piped"));
        await flush();

        expect(Buffer.concat(collected).toString()).toBe("piped");
    });
});
