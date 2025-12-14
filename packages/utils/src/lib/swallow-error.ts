//
// Attempts to execute an operation. If it succeeds, returns the result.
// If it fails, silently swallows the error and returns undefined without logging.
//
export async function swallowError<ReturnT>(operation: () => Promise<ReturnT>): Promise<ReturnT | undefined> {
    try {
        const result = await operation();
        return result;
    }
    catch (error: unknown) {
        // Silently swallow the error - don't log it
        return undefined;
    }
}

