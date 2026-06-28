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
// The default export mirrors `import util from "util"`.
//
const utilModule = { promisify };

export default utilModule;
