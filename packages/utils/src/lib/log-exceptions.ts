import { log } from "./log";

//
// Wraps an async function to log exceptions and rethrow them.
// Useful for IPC handlers and other async functions where you want to log errors
// but still propagate them to the caller.
//
export function logExceptions<T extends (...args: any[]) => Promise<any>>(
    fn: T,
    errorMessage?: string
): T {
    return (async (...args: any[]) => {
        try {
            return await fn(...args);
        }
        catch (error: any) {
            const message = errorMessage || `Exception in ${fn.name || 'anonymous function'}`;
            log.exception(message, error instanceof Error ? error : new Error(String(error)));
            throw error;
        }
    }) as T;
}

