import { serializeError } from "serialize-error";
import { log } from "./log";
import { sleep } from "./sleep";

//
// Retrys a failing operation a number of times.
//
export async function retry<ReturnT>(operation: () => Promise<ReturnT>, maxAttempts: number = 3, waitTimeMS: number = 1000, waitTimeScale = 2): Promise<ReturnT> {

    while (maxAttempts-- > 0) {
        try {
            const result = await operation();
            return result;
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