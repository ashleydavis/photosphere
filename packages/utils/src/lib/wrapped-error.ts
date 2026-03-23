
//
// Formats an error and its full cause chain into a single string.
//
export function formatErrorChain(error: any): string {
    const parts: string[] = [];
    let current = error;
    while (current) {
        parts.push(current.stack || current.message || String(current));
        current = current.cause;
        if (current) {
            parts.push("Caused by:");
        }
    }
    return parts.join("\n");
}

//
// An error that wraps another error to include the original cause.
//
export class WrappedError extends Error {
    constructor(message: string, public options: { cause: Error }) {
        super(message, { cause: options.cause });
    }
}