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
    return new Promise<ReturnT>((resolve, reject) => {
        const timeoutId = setTimeout(() => reject(new Error(`Operation timed out after ${timeoutMS}ms`)), timeoutMS);
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
                if (log.verboseEnabled) {
                    log.verbose("Operation failed with error, will retry.");
                    log.verbose(`Error: ${JSON.stringify(serializeError(error), null, 2)}`);
                }

                await sleep(waitTimeMS);
                waitTimeMS *= waitTimeScale;
            }
            else {
                console.error("Operation failed, no more retries allowed.");

                if (errorContext) {
                    throw new WrappedError(errorContext, { cause: error });
                }

                throw error;
            }
        }
    }

    throw new Error("Expected there to be an error!");
}