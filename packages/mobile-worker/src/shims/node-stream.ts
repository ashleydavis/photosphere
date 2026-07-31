//
// Minimal `stream` shim for the embedded mobile worker.
//
// QuickJS/JavaScriptCore have no Node `stream` module. The storage layer types `readStream` as a
// `Readable`, and `serialization.loadVersion` consumes one via `on('data'|'end'|'error')` and
// `destroy()`. This shim provides a tiny event-based `Readable` that emits a single pre-supplied
// Buffer then ends, which is sufficient for the whole-file read model used on mobile (the native
// fs functions return whole files, not chunks).
//
// `Writable` buffers writes and flushes them whole (the write model the native fs bridge uses), and
// `Transform` is a working transform stream because serving an encrypted asset pipes a file read
// through the encryption layer's decryption stream.
//

import { Buffer } from "buffer";

//
// A registered event listener for a given event name.
//
type StreamListener = (...args: any[]) => void;

//
// The writable end that `pipe()` forwards bytes into. Both the Writable and Transform shims and the
// http ServerResponse satisfy it.
//
export interface IStreamDestination {
    // Accepts a chunk of bytes.
    write(chunk: Buffer): boolean;

    // Signals that no more chunks are coming.
    end?(): void;
}

//
// The transform/flush hooks a Transform is constructed with, mirroring the subset of Node's
// Transform options the encryption streams use.
//
export interface ITransformOptions {
    // Called for each written chunk; emits transformed output through `this.push`.
    transform?: (this: ITransformContext, chunk: Buffer, encoding: string, callback: (error?: Error) => void) => void;

    // Called once the input has ended; may emit trailing output through `this.push`.
    flush?: (this: ITransformContext, callback: (error?: Error) => void) => void;
}

//
// The `this` a transform/flush hook is invoked with: it pushes output downstream.
//
export interface ITransformContext {
    // Queues a chunk of transformed output for emission.
    push(chunk: Buffer | null): boolean;
}

//
// A minimal readable stream over an in-memory Buffer. It emits one `data` event with the whole
// buffer, then `end`, on a microtask so listeners attached synchronously after construction still
// receive the events. `destroy()` stops further emission (used by loadVersion once it has the
// header bytes it needs).
//
export class Readable {
    //
    // Listeners registered per event name.
    //
    protected listeners: Map<string, StreamListener[]> = new Map();

    //
    // The bytes this stream will emit.
    //
    private readonly payload: Buffer;

    //
    // True once destroy() has been called; suppresses pending emission.
    //
    protected destroyed = false;

    //
    // True once emission has been scheduled, so it only happens once.
    //
    private scheduled = false;

    //
    // Builds a readable over the given bytes.
    //
    constructor(payload: Buffer) {
        this.payload = payload;
    }

    //
    // Registers a listener and schedules emission on first listener attach.
    //
    on(eventName: string, listener: StreamListener): this {
        const existing = this.listeners.get(eventName);
        if (existing) {
            existing.push(listener);
        }
        else {
            this.listeners.set(eventName, [listener]);
        }

        this.scheduleEmit();
        return this;
    }

    //
    // Alias of on(), matching the Node EventEmitter surface used by callers.
    //
    once(eventName: string, listener: StreamListener): this {
        return this.on(eventName, listener);
    }

    //
    // Stops the stream; no further events are emitted.
    //
    destroy(): void {
        this.destroyed = true;
    }

    //
    // Forwards this stream's bytes into a writable destination and returns that destination, so
    // `source.pipe(dest)` behaves as callers expect. Attaching the 'data' listener is what schedules
    // emission, so the payload is delivered to the destination and the destination is then ended.
    //
    pipe(destination: IStreamDestination): IStreamDestination {
        this.on("data", (chunk: Buffer) => {
            destination.write(chunk);
        });
        this.on("end", () => {
            if (destination.end) {
                destination.end();
            }
        });
        return destination;
    }

    //
    // Emits an event to all registered listeners, with `this` bound to the stream as Node's
    // EventEmitter does (the AWS SDK's collector reads `this.bufferedBytes` from its listener).
    //
    // An `error` with nobody listening is thrown rather than dropped, which is what Node does and what
    // keeps a failure (a checksum mismatch, say) from disappearing into a stream nobody is watching.
    //
    protected emit(eventName: string, ...args: any[]): void {
        const handlers = this.listeners.get(eventName);
        if (!handlers || handlers.length === 0) {
            if (eventName === "error") {
                throw args[0] instanceof Error ? args[0] : new Error(`Unhandled stream error: ${String(args[0])}`);
            }
            return;
        }

        for (const handler of handlers.slice()) {
            handler.call(this, ...args);
        }
    }

    //
    // Schedules the single data+end emission once, on a microtask. Overridden by Duplex, whose bytes
    // arrive through push() rather than from a fixed payload.
    //
    protected scheduleEmit(): void {
        if (this.scheduled) {
            return;
        }
        this.scheduled = true;

        Promise.resolve().then(() => {
            if (this.destroyed) {
                return;
            }

            this.emit("data", this.payload);

            if (!this.destroyed) {
                this.emit("end");
            }
        });
    }
}

//
// A minimal writable stream that buffers all written chunks in memory and, when ended, flushes the
// concatenated bytes through an onFinish callback (used by createWriteStream to write the whole file
// via the native host bridge). Matches the whole-file write model used across the mobile worker.
//
export class Writable {
    //
    // Listeners registered per event name.
    //
    private listeners: Map<string, StreamListener[]> = new Map();

    //
    // Buffered chunks written so far.
    //
    private chunks: Buffer[] = [];

    //
    // Callback invoked with the full buffer when the stream ends; may throw to signal a write error.
    //
    private readonly onFinish?: (data: Buffer) => void;

    //
    // Builds a writable; onFinish receives the complete buffer when end() is called.
    //
    constructor(onFinish?: (data: Buffer) => void) {
        this.onFinish = onFinish;
    }

    //
    // Buffers a chunk. Returns true (never applies backpressure, since it is in-memory).
    //
    // A subclass that implements Node's `_write` hook gets the chunk through that instead, which is
    // how the AWS SDK's response collector (a Writable subclass whose only body is `_write`) gathers
    // the bytes. Without this its buffer stays empty and every S3 response reads as zero-length.
    //
    write(chunk: Buffer | Uint8Array | string): boolean {
        const buffer = typeof chunk === "string" ? Buffer.from(chunk) : Buffer.from(chunk);
        const writeHook = (this as any)._write;
        if (typeof writeHook === "function") {
            writeHook.call(this, buffer, "buffer", (error?: Error) => {
                if (error) {
                    this.emit("error", error);
                }
            });
            return true;
        }
        this.chunks.push(buffer);
        return true;
    }

    //
    // Ends the stream: optionally writes a final chunk, flushes the buffer via onFinish, then emits
    // 'finish' (or 'error' if onFinish throws).
    //
    end(chunk?: Buffer | Uint8Array | string): void {
        if (chunk !== undefined) {
            this.write(chunk);
        }
        const finalHook = (this as any)._final;
        if (typeof finalHook === "function") {
            finalHook.call(this, (error?: Error) => {
                if (error) {
                    this.emit("error", error);
                    return;
                }
                this.emit("finish");
            });
            return;
        }
        if (!this.onFinish && this.chunks.length > 0) {
            // Bytes were written to a stream with no `_write` hook and no onFinish sink, so there is
            // nowhere for them to go. Dropping them silently would look like a successful write of
            // data that never landed anywhere.
            throw new Error(`Writable received ${Buffer.concat(this.chunks).length} bytes but has no destination: `
                + `it was constructed without an onFinish sink and the subclass implements no _write hook.`);
        }
        try {
            if (this.onFinish) {
                this.onFinish(Buffer.concat(this.chunks));
            }
            this.emit("finish");
        }
        catch (error) {
            this.emit("error", error);
        }
    }

    //
    // Registers a listener.
    //
    on(eventName: string, listener: StreamListener): this {
        const existing = this.listeners.get(eventName);
        if (existing) {
            existing.push(listener);
        }
        else {
            this.listeners.set(eventName, [listener]);
        }
        return this;
    }

    //
    // Alias of on().
    //
    once(eventName: string, listener: StreamListener): this {
        return this.on(eventName, listener);
    }

    //
    // Emits an event to all registered listeners, with `this` bound to the stream as Node's
    // EventEmitter does (the AWS SDK's collector reads `this.bufferedBytes` from its listener).
    //
    protected emit(eventName: string, ...args: any[]): void {
        const handlers = this.listeners.get(eventName);
        if (!handlers || handlers.length === 0) {
            // An error with nobody listening is thrown rather than dropped, as Node does.
            if (eventName === "error") {
                throw args[0] instanceof Error ? args[0] : new Error(`Unhandled stream error: ${String(args[0])}`);
            }
            return;
        }
        for (const handler of handlers.slice()) {
            handler.call(this, ...args);
        }
    }
}

//
// Transform is a working transform stream, and is still defined as a plain function (NOT an ES6
// class) so ES5-style consumers can subclass it via `inherits` and invoke it with
// `Base.call(this)` (the pattern used by `cipher-base`, a transitive dependency of the crypto
// `create-hash` shim). An ES6 class cannot be called without `new` and would throw "class
// constructors must be invoked with 'new'".
//
// Real streaming behaviour IS required: the encryption layer builds its decryption stream as
// `new Transform({ transform, flush })` and `encrypted-storage.readStream` pipes a file read into
// it, so serving an encrypted asset depends on this emitting the decrypted bytes. Output is
// buffered until a 'data' listener attaches, because the source Readable emits on a microtask and
// can therefore deliver its payload before the consumer (the asset server's `pipeline`) is hooked up.
//
export const Transform = function Transform(this: any, options?: ITransformOptions): void {
    this.shimListeners = new Map<string, StreamListener[]>();
    this.shimPending = [] as Buffer[];
    this.shimTransform = options && options.transform;
    this.shimFlush = options && options.flush;
    this.shimInputEnded = false;
    this.shimEndEmitted = false;
    this.shimDrainScheduled = false;
    this.shimDestroyed = false;
} as unknown as { new (options?: ITransformOptions): any };

const transformPrototype: any = (Transform as any).prototype;

//
// Registers a listener. Attaching one may make buffered output deliverable, so a drain is scheduled.
//
transformPrototype.on = function (eventName: string, listener: StreamListener): any {
    const existing = this.shimListeners.get(eventName);
    if (existing) {
        existing.push(listener);
    }
    else {
        this.shimListeners.set(eventName, [listener]);
    }
    this.scheduleDrain();
    return this;
};

//
// Alias of on(), matching the Node EventEmitter surface used by callers.
//
transformPrototype.once = function (eventName: string, listener: StreamListener): any {
    return this.on(eventName, listener);
};

//
// Emits an event to all registered listeners.
//
transformPrototype.emit = function (eventName: string, ...args: any[]): boolean {
    const handlers = this.shimListeners.get(eventName);
    if (!handlers) {
        return false;
    }
    for (const handler of handlers.slice()) {
        handler(...args);
    }
    return true;
};

//
// Queues transformed output. Called by the transform/flush hooks as `this.push(...)`.
//
transformPrototype.push = function (chunk: Buffer | null): boolean {
    if (chunk === null || chunk === undefined) {
        return true;
    }
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    if (buffer.length > 0) {
        this.shimPending.push(buffer);
    }
    this.scheduleDrain();
    return true;
};

//
// Feeds a chunk through the transform hook (or straight through when no hook was supplied).
//
transformPrototype.write = function (chunk: Buffer): boolean {
    if (this.shimDestroyed) {
        return false;
    }
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    if (this.shimTransform) {
        this.shimTransform.call(this, buffer, "buffer", (error?: Error) => {
            if (error) {
                this.emit("error", error);
            }
        });
    }
    else {
        this.push(buffer);
    }
    return true;
};

//
// Ends the input, running the flush hook so it can emit any trailing output.
//
transformPrototype.end = function (chunk?: Buffer): any {
    if (chunk !== undefined && chunk !== null) {
        this.write(chunk);
    }
    if (this.shimInputEnded) {
        return this;
    }
    this.shimInputEnded = true;
    if (this.shimFlush) {
        this.shimFlush.call(this, (error?: Error) => {
            if (error) {
                this.emit("error", error);
            }
            this.scheduleDrain();
        });
    }
    else {
        this.scheduleDrain();
    }
    return this;
};

//
// Forwards this stream's output into a writable destination and returns that destination.
//
transformPrototype.pipe = function (destination: IStreamDestination): IStreamDestination {
    this.on("data", (chunk: Buffer) => {
        destination.write(chunk);
    });
    this.on("end", () => {
        if (destination.end) {
            destination.end();
        }
    });
    return destination;
};

//
// Stops the stream; no further output is emitted.
//
transformPrototype.destroy = function (error?: Error): any {
    this.shimDestroyed = true;
    if (error) {
        this.emit("error", error);
    }
    return this;
};

//
// Delivers buffered output on a microtask, then 'end' once the input has ended and everything has
// been handed over. Holding output until a 'data' listener exists is what makes the stream safe to
// hook up after the source has already produced its bytes.
//
transformPrototype.scheduleDrain = function (): void {
    if (this.shimDrainScheduled) {
        return;
    }
    this.shimDrainScheduled = true;

    Promise.resolve().then(() => {
        this.shimDrainScheduled = false;
        if (this.shimDestroyed) {
            return;
        }

        const dataHandlers = this.shimListeners.get("data");
        if (dataHandlers && dataHandlers.length > 0) {
            while (this.shimPending.length > 0) {
                this.emit("data", this.shimPending.shift());
            }
        }

        if (this.shimInputEnded && this.shimPending.length === 0 && !this.shimEndEmitted) {
            this.shimEndEmitted = true;
            this.emit("end");
            this.emit("finish");
        }
    });
};

//
// A working duplex stream: readable on one side, writable on the other.
//
// The AWS SDK's `ChecksumStream` extends this to verify a response checksum, so it has to be real
// rather than a no-op base. It must also be an instance of `Readable`, because `sdkStreamMixin`
// decides between its Node and web code paths with `stream instanceof Readable` and throws
// "Unexpected stream implementation" when the check fails.
//
// The readable half is push-driven (the payload emission Readable schedules is suppressed), and the
// writable half calls the subclass's `_write` / `_final` hooks the way Node does.
//
export class Duplex extends Readable {
    //
    // True once push(null) has ended the readable side, so `end` is emitted once.
    //
    private readableEnded = false;

    //
    // True once a consumer has attached a `data` listener. Until then the readable side is paused and
    // pushed bytes are buffered, as Node's is.
    //
    private flowing = false;

    //
    // Bytes pushed before a consumer started reading.
    //
    private buffered: Buffer[] = [];

    //
    // True once push(null) has been called but the buffered bytes have not been flushed yet, so `end`
    // fires after the last `data`.
    //
    private endPending = false;

    //
    // Guards against scheduling more than one deferred flush.
    //
    private flushScheduled = false;

    //
    // Builds a duplex with no fixed payload; its bytes arrive through push().
    //
    constructor() {
        super(Buffer.alloc(0));
    }

    //
    // Suppresses Readable's payload emission: a Duplex has no payload to emit.
    //
    protected scheduleEmit(): void {
        // No-op: push() drives emission instead.
    }

    //
    // Registers a listener, and starts the stream flowing when the first `data` listener attaches.
    //
    // The flush is deferred to a microtask so listeners the consumer attaches immediately afterwards
    // (the AWS SDK's collector attaches `error` and `finish` right after piping) are in place before
    // any event fires.
    //
    on(eventName: string, listener: StreamListener): this {
        super.on(eventName, listener);
        if (eventName === "data" && !this.flowing) {
            this.flowing = true;
            this.scheduleFlush();
        }
        return this;
    }

    //
    // Emits a chunk to the readable side, or ends it when passed null.
    //
    // While no consumer is reading the bytes are buffered rather than emitted. The AWS SDK relies on
    // this: its checksum stream receives the whole response body while it is being verified, and only
    // afterwards does the SDK attach the collector that consumes it. Emitting on push would deliver
    // every byte to nobody, and the read would hang until the retry timeout.
    //
    push(chunk: Buffer | null): boolean {
        if (this.destroyed) {
            return false;
        }
        if (chunk === null) {
            this.endPending = true;
            this.scheduleFlush();
            return false;
        }
        this.buffered.push(chunk);
        this.scheduleFlush();
        return true;
    }

    //
    // Flushes buffered bytes (and then `end`) to a reading consumer, once, on a microtask.
    //
    private scheduleFlush(): void {
        if (!this.flowing || this.flushScheduled) {
            return;
        }
        this.flushScheduled = true;

        Promise.resolve().then(() => {
            this.flushScheduled = false;
            if (this.destroyed) {
                return;
            }

            const pending = this.buffered.splice(0);
            for (const chunk of pending) {
                this.emit("data", chunk);
            }

            if (this.endPending && !this.readableEnded) {
                this.readableEnded = true;
                this.emit("end");
            }
        });
    }

    //
    // Accepts a chunk on the writable side, handing it to the subclass's `_write` hook. `encoding`
    // and `callback` are the remaining arguments of Node's signature; a caller such as `pipe()`
    // passes neither.
    //
    write(chunk: Buffer | Uint8Array | string, encoding?: string, callback?: (error?: Error) => void): boolean {
        const buffer = typeof chunk === "string" ? Buffer.from(chunk) : Buffer.from(chunk);
        const writeHook = (this as any)._write;
        const done = (error?: Error) => {
            if (error) {
                this.emit("error", error);
            }
            if (callback) {
                callback(error);
            }
        };
        if (typeof writeHook === "function") {
            writeHook.call(this, buffer, encoding || "buffer", done);
        }
        else {
            this.push(buffer);
            done();
        }
        return true;
    }

    //
    // Ends the writable side, running the subclass's `_final` hook so it can flush (which is where
    // ChecksumStream compares the digest) before the readable side is ended.
    //
    end(chunk?: Buffer | Uint8Array | string): void {
        if (chunk !== undefined) {
            this.write(chunk);
        }
        const finalHook = (this as any)._final;
        if (typeof finalHook === "function") {
            finalHook.call(this, (error?: Error) => {
                if (error) {
                    this.emit("error", error);
                    return;
                }
                this.push(null);
                this.emit("finish");
            });
            return;
        }
        this.push(null);
        this.emit("finish");
    }
}

//
// A duplex that republishes whatever is written to it, matching Node's PassThrough.
//
// `@smithy/util-stream`'s `splitStream` constructs one of these for every retryable request body, so
// an upload from the mobile worker runs through it. While it was a no-op base constructor it had no
// write, push or pipe at all, and the first upload to reach it would have failed on a missing method.
//
export class PassThrough extends Duplex {
    //
    // Forwards a written chunk straight to the readable side.
    //
    _write(chunk: Buffer, encoding: string, callback: (error?: Error) => void): void {
        this.push(chunk);
        callback();
    }
}

//
// The base `Stream` constructor. In Node `require("stream")` IS this constructor (with Readable,
// Writable, etc. attached as properties), and packages like `send` do `util.inherits(SubClass, Stream)`
// at module-eval time. It is a plain function (not an ES6 class) so it works as an inheritance super
// and can be called without `new`. No streaming behaviour is required on it.
//
export const Stream = function Stream(this: any): void {
    // No-op base constructor.
} as unknown as { new (): any };

// Attach the stream subclasses so `import stream from "stream"; stream.Readable` resolves as in Node.
(Stream as any).Readable = Readable;
(Stream as any).Writable = Writable;
(Stream as any).Duplex = Duplex;
(Stream as any).Transform = Transform;
(Stream as any).PassThrough = PassThrough;

//
// The default export mirrors `import stream from "stream"` — the Stream constructor itself (with the
// subclasses attached above).
//
export default Stream;
