//
// Installs the JS globals the bundled storage/database code expects but the bare embedded engine
// (QuickJS/JavaScriptCore) does not provide: `Buffer`, a minimal `process`, and a `global` alias.
//
// This module is imported FIRST by the worker entry so the globals exist before any storage module
// evaluates. In particular `bson` selects its Node vs web byte-utils at import time based on
// `globalThis.Buffer`, so installing `Buffer` first makes bson use the Buffer code path (no
// dependency on TextEncoder/TextDecoder, which the engine may lack).
//

import { Buffer } from "buffer";

//
// A minimal `process` stand-in covering what the bundled code reads: `env` (credential resolution),
// `pid` (write-lock logging, never hit on the read path), `platform`, and `nextTick`.
//
interface IMinimalProcess {
    // Environment variables; empty on mobile (no credentials configured here).
    env: Record<string, string | undefined>;

    // A fake process id; only referenced by write-lock logging, which the read path does not use.
    pid: number;

    // The platform identifier.
    platform: string;

    // Empty argv to satisfy any incidental reads.
    argv: string[];

    // Schedules a callback on the microtask queue, matching process.nextTick semantics closely enough.
    nextTick: (callback: (...args: any[]) => void, ...args: any[]) => void;

    // Returns the current working directory; sandbox-relative empty string on mobile.
    cwd: () => string;
}

//
// A pending timer registered via setTimeout or setInterval.
//
interface IPendingTimer {
    // The timer id returned to the caller (used by clearTimeout/clearInterval).
    id: number;

    // The callback to run when the timer fires.
    callback: (...args: any[]) => void;

    // Virtual milliseconds remaining until this timer next fires. Advanced by the pump.
    remaining: number;

    // For a repeating timer (setInterval), the period to re-arm to after firing; null for a one-shot.
    interval: number | null;

    // Extra arguments forwarded to the callback.
    args: any[];
}

//
// Installs setTimeout/clearTimeout and setInterval/clearInterval backed by an idle-driven timer queue.
//
// The embedded engine (QuickJS/JavaScriptCore) has no timer loop: the native engine drives a task by
// repeatedly draining the JS microtask queue. So timers cannot fire on a real clock. Instead, timers
// are queued here and fired one at a time by the native pump (via globalThis.__pumpTimers) ONLY when
// the microtask queue is drained and the task has not yet settled. A virtual clock advances by the
// smallest remaining delay each pump, so the earliest timer fires first and relative ordering is
// preserved: a 1s broadcast interval fires many times before a 60s timeout guard, and an interval
// re-arms after each firing (LAN-share's receiver broadcasts on setInterval and both roles poll
// cancellation on setInterval, while overall timeouts use setTimeout).
//
export function installTimers(globalScope: any): void {
    // Only install the queue on an engine that lacks timers (QuickJS/JavaScriptCore). Where a real
    // setTimeout exists (Node/Bun, used by the off-device harness and tests), keep it.
    if (typeof globalScope.setTimeout === "function") {
        return;
    }

    const timers: IPendingTimer[] = [];
    let nextTimerId = 1;

    globalScope.setTimeout = (callback: (...args: any[]) => void, delay?: number, ...args: any[]): number => {
        const id = nextTimerId++;
        timers.push({ id, callback, remaining: delay && delay > 0 ? delay : 0, interval: null, args });
        return id;
    };

    globalScope.setInterval = (callback: (...args: any[]) => void, delay?: number, ...args: any[]): number => {
        const id = nextTimerId++;
        // Clamp the period to at least 1ms so a 0-delay interval cannot starve the virtual clock.
        const period = delay && delay > 0 ? delay : 1;
        timers.push({ id, callback, remaining: period, interval: period, args });
        return id;
    };

    const removeTimer = (id: number): void => {
        const index = timers.findIndex(timer => timer.id === id);
        if (index >= 0) {
            timers.splice(index, 1);
        }
    };

    globalScope.clearTimeout = (id: number): void => {
        removeTimer(id);
    };

    globalScope.clearInterval = (id: number): void => {
        removeTimer(id);
    };

    // Advances the virtual clock and fires the earliest pending timer if it is due. An optional
    // `maxAdvanceMs` bounds how far the clock may advance this call: when the earliest timer is further
    // out than the budget, the clock advances by the budget and no timer fires. A native pump passes the
    // real milliseconds elapsed since its last call as the budget, so the virtual clock tracks real time
    // and a large timeout guard (e.g. a 90-minute retry timeout) never fires prematurely and aborts an
    // in-flight operation. When called with no budget (the Android pump) it fires the earliest timer
    // regardless, preserving the original behaviour. Records the virtual ms advanced in
    // globalThis.__lastTimerAdvanceMs and the next timer's remaining ms in globalThis.__nextTimerMs (-1
    // when none), so the native pump can pace and schedule its next call. Returns true when a timer fired.
    globalScope.__pumpTimers = (maxAdvanceMs?: number): boolean => {
        if (timers.length === 0) {
            globalScope.__lastTimerAdvanceMs = 0;
            globalScope.__nextTimerMs = -1;
            return false;
        }

        let earliestIndex = 0;
        for (let index = 1; index < timers.length; index++) {
            if (timers[index].remaining < timers[earliestIndex].remaining) {
                earliestIndex = index;
            }
        }

        const earliest = timers[earliestIndex].remaining;

        // The earliest timer is not yet due within the real-time budget: advance the clock by the
        // budget and fire nothing, so timers count down at real-time rate.
        if (maxAdvanceMs !== undefined && maxAdvanceMs !== null && earliest > maxAdvanceMs) {
            if (maxAdvanceMs > 0) {
                for (const timer of timers) {
                    timer.remaining -= maxAdvanceMs;
                }
            }
            globalScope.__lastTimerAdvanceMs = maxAdvanceMs;
            let nextRemaining = timers[0].remaining;
            for (let index = 1; index < timers.length; index++) {
                if (timers[index].remaining < nextRemaining) {
                    nextRemaining = timers[index].remaining;
                }
            }
            globalScope.__nextTimerMs = nextRemaining;
            return false;
        }

        const advance = earliest;
        globalScope.__lastTimerAdvanceMs = advance;
        if (advance > 0) {
            for (const timer of timers) {
                timer.remaining -= advance;
            }
        }

        const timer = timers[earliestIndex];
        if (timer.interval !== null) {
            timer.remaining = timer.interval;
        }
        else {
            timers.splice(earliestIndex, 1);
        }
        timer.callback(...timer.args);

        let nextRemaining = -1;
        for (const pending of timers) {
            if (nextRemaining < 0 || pending.remaining < nextRemaining) {
                nextRemaining = pending.remaining;
            }
        }
        globalScope.__nextTimerMs = nextRemaining;
        return true;
    };
}

//
// Installs minimal TextEncoder/TextDecoder and atob/btoa, backed by Buffer.
//
// The `bson` browser build (selected because the worker bundle targets the engine, not Node) uses
// these Web APIs for UTF-8 and base64 conversion, but QuickJS/JavaScriptCore do not provide them.
// Buffer (installed above) implements the same conversions, so these wrappers are thin and correct
// for the UTF-8 / base64 use bson makes of them.
//
export function installTextCodecs(globalScope: any): void {
    if (typeof globalScope.TextDecoder !== "function") {
        globalScope.TextDecoder = class TextDecoder {
            // The text encoding (only utf-8 is used by bson).
            private readonly encoding: string;

            // Stores the requested encoding, defaulting to utf-8.
            constructor(label?: string) {
                this.encoding = label || "utf-8";
            }

            // Decodes bytes (TypedArray/ArrayBuffer) into a string using the stored encoding.
            decode(input?: ArrayBuffer | ArrayBufferView): string {
                if (!input) {
                    return "";
                }

                const view = input instanceof ArrayBuffer
                    ? new Uint8Array(input)
                    : new Uint8Array((input as ArrayBufferView).buffer, (input as ArrayBufferView).byteOffset, (input as ArrayBufferView).byteLength);
                const bufferEncoding = this.encoding === "utf-8" || this.encoding === "utf8" ? "utf8" : (this.encoding as BufferEncoding);
                return Buffer.from(view).toString(bufferEncoding);
            }
        };
    }

    if (typeof globalScope.TextEncoder !== "function") {
        globalScope.TextEncoder = class TextEncoder {
            // The fixed encoding, matching the Web API (always utf-8).
            readonly encoding = "utf-8";

            // Encodes a string into UTF-8 bytes.
            encode(input?: string): Uint8Array {
                return new Uint8Array(Buffer.from(input || "", "utf8"));
            }
        };
    }

    if (typeof globalScope.btoa !== "function") {
        globalScope.btoa = (input: string): string => Buffer.from(input, "binary").toString("base64");
    }

    if (typeof globalScope.atob !== "function") {
        globalScope.atob = (input: string): string => Buffer.from(input, "base64").toString("binary");
    }
}

//
// Installs a minimal `crypto.getRandomValues`.
//
// The embedded engine has no Web Crypto. The `uuid` package (used by RandomUuidGenerator to mint
// database/asset ids) calls `crypto.getRandomValues`, so a polyfill is required. It fills the target
// typed array's underlying bytes from Math.random. This is NOT cryptographically secure; it is only
// used for id generation on device, where uniqueness (not unpredictability) is what matters.
//
export function installCrypto(globalScope: any): void {
    if (globalScope.crypto && typeof globalScope.crypto.getRandomValues === "function") {
        return;
    }

    const cryptoObject = globalScope.crypto || {};
    cryptoObject.getRandomValues = (typedArray: ArrayBufferView): ArrayBufferView => {
        const bytes = new Uint8Array(typedArray.buffer, typedArray.byteOffset, typedArray.byteLength);
        for (let index = 0; index < bytes.length; index++) {
            bytes[index] = Math.floor(Math.random() * 256);
        }
        return typedArray;
    };
    globalScope.crypto = cryptoObject;
}

//
// Installs a minimal `performance.now()`.
//
// Some bundled code measures elapsed time with `performance.now()`, which the embedded engine does
// not provide. It is backed by Date.now() (millisecond resolution is sufficient for the timing/log
// uses on the read and write paths).
//
export function installPerformance(globalScope: any): void {
    if (globalScope.performance && typeof globalScope.performance.now === "function") {
        return;
    }

    const performanceObject = globalScope.performance || {};
    performanceObject.now = (): number => Date.now();
    globalScope.performance = performanceObject;
}

//
// Installs Buffer and process onto the given scope (defaulting to globalThis) if not already
// present. The scope parameter exists so unit tests can install onto a fake scope object and assert
// the result without mutating the real global environment.
//
export function installGlobals(globalScope: any = globalThis): void {
    // Alias `global` to the global scope so bundled browser builds that read the bare `global`
    // identifier at module-init time do not throw a ReferenceError on the embedded engine (which
    // exposes only `globalThis`, not `global`). `randombytes`' browser build, for example, reads
    // `global.crypto` at init; installed here (before any storage/crypto module evaluates) it
    // resolves to the crypto shim installed below, so its module init succeeds instead of aborting
    // the whole bundle evaluation. Node/Bun already define `global`, so this is a no-op there.
    if (!globalScope.global) {
        globalScope.global = globalScope;
    }

    if (!globalScope.Buffer) {
        globalScope.Buffer = Buffer;
    }

    installTextCodecs(globalScope);

    installTimers(globalScope);

    installCrypto(globalScope);

    installPerformance(globalScope);

    if (!globalScope.process) {
        const minimalProcess: IMinimalProcess = {
            env: {},
            pid: 0,
            platform: "android",
            argv: [],
            nextTick: (callback, ...args) => {
                Promise.resolve().then(() => callback(...args));
            },
            cwd: () => "",
        };
        globalScope.process = minimalProcess;
    }
}

// Install immediately on import so globals exist before later imports evaluate.
installGlobals();
