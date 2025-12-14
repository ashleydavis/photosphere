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
        catch (err: any) {
            if (maxAttempts >= 1) {
                console.error("Operation failed, will retry.");
                console.error("Error:");
                console.error(err && err.stack || err);

                await sleep(waitTimeMS);
                waitTimeMS *= waitTimeScale;
            }
            else {
                console.error("Operation failed, no more retries allowed.");

                throw err;
            }
        }
    }

    throw new Error("Expected there to be an error!");
}