import { log } from "./log";
import { sleep } from "./sleep";

//
// Retries a failing operation a number of times. If all retries fail,
// logs the error and returns undefined instead of throwing.
//
export async function retryOrLog<ReturnT>(operation: () => Promise<ReturnT>, errorMessage: string, maxAttempts: number = 3, waitTimeMS: number = 1000, waitTimeScale = 2): Promise<ReturnT | undefined> {
    let lastError: any | undefined;

    while (maxAttempts-- > 0) {
        try {
            const result = await operation();
            return result;
        }
        catch (error: any) {
            lastError = error;

            if (maxAttempts >= 1) {
                log.exception("Operation failed, will retry.", error);

                await sleep(waitTimeMS);
                waitTimeMS *= waitTimeScale;
            }
            else {
                const message = errorMessage || "Operation failed after all retries";
                log.exception(message, error);
                return undefined;
            }
        }
    }

    // This should never be reached, but TypeScript needs it for type safety
    return undefined;
}

