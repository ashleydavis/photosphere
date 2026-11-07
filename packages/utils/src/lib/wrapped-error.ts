
//
// Formats an error and its full cause chain into a single string.
//
export function formatErrorChain(error: any): string {
    const parts: string[] = [];
    let current = error;
    while (current) {
        const stack = current.stack;
        const message = current.message;
        if (stack && message && !stack.includes(message)) {
            // JavaScriptCore (iOS) stacks contain only frames and omit the leading "Error: message"
            // line that V8 (Android/desktop) includes, so prepend the message when the stack lacks it.
            // This keeps error messages visible in logs consistently across JS engines.
            parts.push(`${message}\n${stack}`);
        }
        else {
            parts.push(stack || message || String(current));
        }
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
        // The cause's message is folded into this one as well as kept as the cause.
        //
        // Somewhere a cause is all there is to go on, and the message is all that survives: the
        // embedded mobile engine hands a failed task's `error.message` to native and nothing else, so
        // a background sync on a phone reported "Failed to copy file asset/0178e5ff..." over and over
        // with no way to find out what went wrong with it.
        super(options.cause?.message ? `${message}: ${options.cause.message}` : message, { cause: options.cause });
    }
}