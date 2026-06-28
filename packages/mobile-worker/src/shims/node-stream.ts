//
// Minimal `stream` shim for the embedded mobile worker.
//
// QuickJS/JavaScriptCore have no Node `stream` module. The storage layer types `readStream` as a
// `Readable`, and `serialization.loadVersion` consumes one via `on('data'|'end'|'error')` and
// `destroy()`. This shim provides a tiny event-based `Readable` that emits a single pre-supplied
// Buffer then ends, which is sufficient for the whole-file read model used on mobile (the native
// fs functions return whole files, not chunks).
//
// The write side (`Writable`, `pipeline`) is not needed by the read path and is intentionally
// absent here; the `stream/promises` shim throws NOT IMPLEMENTED for `pipeline`.
//

import { Buffer } from "buffer";

//
// A registered event listener for a given event name.
//
type StreamListener = (...args: any[]) => void;

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
    private listeners: Map<string, StreamListener[]> = new Map();

    //
    // The bytes this stream will emit.
    //
    private readonly payload: Buffer;

    //
    // True once destroy() has been called; suppresses pending emission.
    //
    private destroyed = false;

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
    // Emits an event to all registered listeners.
    //
    private emit(eventName: string, ...args: any[]): void {
        const handlers = this.listeners.get(eventName);
        if (!handlers) {
            return;
        }

        for (const handler of handlers.slice()) {
            handler(...args);
        }
    }

    //
    // Schedules the single data+end emission once, on a microtask.
    //
    private scheduleEmit(): void {
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
    write(chunk: Buffer | Uint8Array | string): boolean {
        this.chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : Buffer.from(chunk));
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
    // Emits an event to all registered listeners.
    //
    private emit(eventName: string, ...args: any[]): void {
        const handlers = this.listeners.get(eventName);
        if (!handlers) {
            return;
        }
        for (const handler of handlers.slice()) {
            handler(...args);
        }
    }
}

//
// Duplex/Transform/PassThrough are exported as minimal no-op base "classes" defined as plain
// functions (NOT ES6 classes) so that ES5-style consumers can both subclass them via `inherits` and
// invoke them with `Base.call(this)` (the pattern used by `cipher-base`, a transitive dependency of
// the crypto `create-hash` shim). An ES6 class cannot be called without `new` and would throw
// "class constructors must be invoked with 'new'". These are only used as inheritance bases; no
// real streaming behaviour is required on the read/write paths the mobile worker exercises.
//
export const Transform = function Transform(this: any): void {
    // No-op base constructor.
} as unknown as { new (): any };

//
// See Transform.
//
export const Duplex = function Duplex(this: any): void {
    // No-op base constructor.
} as unknown as { new (): any };

//
// See Transform.
//
export const PassThrough = function PassThrough(this: any): void {
    // No-op base constructor.
} as unknown as { new (): any };

//
// The default export mirrors `import stream from "stream"`.
//
const streamModule = { Readable, Writable, Duplex, Transform, PassThrough };

export default streamModule;
