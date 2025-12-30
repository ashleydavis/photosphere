import { log } from "./log";

//
// Attempts to execute an operation. If it succeeds, returns the result.
// If it fails, logs the error and returns undefined.
//
export async function tryOrLog<ReturnT>(operation: () => Promise<ReturnT>, errorMessage?: string): Promise<ReturnT | undefined> {
    try {
        const result = await operation();
        return result;
    }
    catch (error: any) {
        const message = errorMessage || "Operation failed";
        log.exception(message, error);
        return undefined;
    }
}

