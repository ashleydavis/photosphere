import { serializeError } from "serialize-error";
import { log } from "./log";
import { sleep } from "./sleep";
import { WrappedError } from "./wrapped-error";

//
// Returns a promise that rejects after the given number of milliseconds.
//
export async function rejectAfter<ReturnT>(ms: number): Promise<ReturnT> {
    await sleep(ms);
    throw new Error(`Operation timed out after ${ms}ms`);
}

//
// Attempts an operation once, rejecting if it doesn't complete within timeoutMS.
//
export async function retryOnce<ReturnT>(operation: () => Promise<ReturnT>, timeoutMS: number): Promise<ReturnT> {
    // What the operation is, read from its own source.
    //
    // A timeout is raised by a timer rather than by the work, so the error it throws carries the
    // timer's stack and says nothing about what was being waited for. "Operation timed out after
    // 30000ms" was the whole of what a failing background sync reported on a phone, pass after pass,
    // and there are dozens of retries it could have come from. A stack does not help either: the
    // callers are async, and the embedded engine shows only the two synchronous frames inside this
    // file. The operation's own text does, because these are all one-line arrow functions naming the
    // call they make.
    const operationSource = operation.toString().replace(/\s+/g, " ").slice(0, 200);

    return new Promise<ReturnT>((resolve, reject) => {
        const timeoutId = setTimeout(() => reject(new Error(`Operation timed out after ${timeoutMS}ms: ${operationSource}`)), timeoutMS);
        operation().then(
            result => {
                clearTimeout(timeoutId);
                resolve(result);
            },
            error => {
                clearTimeout(timeoutId);
                reject(error);
            }
        );
    });
}

//
// Retrys a failing operation a number of times.
// Each attempt is raced against a timeout and rejected if it doesn't complete in time.
//
export async function retry<ReturnT>(operation: () => Promise<ReturnT>, maxAttempts: number = 3, waitTimeMS: number = 1_000, waitTimeScale: number = 2, timeoutMS: number = 30_000, errorContext?: string): Promise<ReturnT> {

    while (maxAttempts-- > 0) {
        try {
            return await retryOnce(operation, timeoutMS);
        }
        catch (error: any) {
            if (maxAttempts >= 1) {
                // What went wrong on an attempt that is about to be tried again, said once, in one
                // line. It used to be verbose-only, and the last attempt's error was the only one
                // anyone ever saw: on a phone that made a failure that takes three attempts and a
                // minute and a half look like a single event with a single cause, and hid that the
                // first attempt failed differently from the ones that followed it.
                log.warn(`${errorContext ?? "An operation failed"}. Retrying after: ${error?.message ?? String(error)}`);

                if (log.verboseEnabled) {
                    log.verbose(`Error: ${JSON.stringify(serializeError(error), null, 2)}`);
                }

                await sleep(waitTimeMS);
                waitTimeMS *= waitTimeScale;
            }
            else {
                console.error(`Operation failed, no more retries allowed. Last error: ${error?.stack ?? error?.message ?? String(error)}`);

                if (errorContext) {
                    throw new WrappedError(errorContext, { cause: error });
                }

                throw error;
            }
        }
    }

    throw new Error("Expected there to be an error!");
}