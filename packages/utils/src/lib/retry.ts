import { serializeError } from "serialize-error";
import { log } from "./log";
import { sleep } from "./sleep";

//
// Returns a promise that rejects after the given number of milliseconds.
//
export async function rejectAfter<ReturnT>(ms: number): Promise<ReturnT> {
    await sleep(ms);
    throw new Error(`Operation timed out after ${ms}ms`);
}

//
// Retrys a failing operation a number of times.
// Each attempt is raced against a timeout and rejected if it doesn't complete in time.
//
export async function retry<ReturnT>(operation: () => Promise<ReturnT>, maxAttempts: number = 3, waitTimeMS: number = 1_000, waitTimeScale: number = 2, timeoutMS: number = 30_000): Promise<ReturnT> {

    while (maxAttempts-- > 0) {
        try {
            return await Promise.race([
                operation(),
                rejectAfter<ReturnT>(timeoutMS),
            ]);
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

                throw error;
            }
        }
    }

    throw new Error("Expected there to be an error!");
}