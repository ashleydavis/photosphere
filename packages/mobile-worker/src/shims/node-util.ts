//
// Minimal `util` shim for the embedded mobile worker.
//
// node-utils' `exec` helper calls `promisify(exec)` at module load. Only `promisify` is needed, and
// a faithful minimal implementation suffices: it wraps a callback-style function into a
// Promise-returning one. The wrapped function (exec) throws when called on mobile, but wrapping it
// at import time is harmless.
//

//
// Wraps a Node callback-style function (last arg is (error, result) => void) into one that returns
// a Promise. Matches the subset of util.promisify the bundled code relies on.
//
export function promisify(original: (...args: any[]) => void): (...args: any[]) => Promise<any> {
    return function promisified(...args: any[]): Promise<any> {
        return new Promise((resolve, reject) => {
            original(...args, (error: unknown, result: unknown) => {
                if (error) {
                    reject(error);
                }
                else {
                    resolve(result);
                }
            });
        });
    };
}

//
// Sets up prototype inheritance the way Node's `util.inherits` does: records the super constructor
// on `super_` and points the subclass prototype at the super prototype. Several express/connect
// dependencies (notably `send`) call this at module-eval time, so it must exist and accept a real
// constructor as the super.
//
export function inherits(constructor: any, superConstructor: any): void {
    constructor.super_ = superConstructor;
    if (superConstructor && superConstructor.prototype) {
        Object.setPrototypeOf(constructor.prototype, superConstructor.prototype);
    }
}

//
// Returns a no-op logger, matching `util.debuglog` closely enough for the bundled code (which only
// ever calls the returned function, never enables it).
//
export function debuglog(): (...args: any[]) => void {
    return function debugNoop(): void {
        // Debug logging is disabled in the embedded engine.
    };
}

//
// Minimal `util.format`: substitutes %s/%d/%j tokens and joins any extra args with spaces. Covers the
// formatting the bundled code performs in error messages.
//
export function format(formatString?: any, ...args: any[]): string {
    if (typeof formatString !== "string") {
        return [formatString, ...args].map(value => String(value)).join(" ");
    }
    let index = 0;
    let result = formatString.replace(/%[sdj%]/g, token => {
        if (token === "%%") {
            return "%";
        }
        if (index >= args.length) {
            return token;
        }
        const value = args[index++];
        if (token === "%j") {
            return JSON.stringify(value);
        }
        if (token === "%d") {
            return String(Number(value));
        }
        return String(value);
    });
    for (; index < args.length; index++) {
        result += " " + String(args[index]);
    }
    return result;
}

//
// Minimal `util.inspect`: returns the value's string form. The bundled code only uses it for log/error text.
//
export function inspect(value: any): string {
    return typeof value === "string" ? value : JSON.stringify(value);
}

//
// The default export mirrors `import util from "util"`.
//
const utilModule = { promisify, inherits, debuglog, format, inspect };

export default utilModule;
