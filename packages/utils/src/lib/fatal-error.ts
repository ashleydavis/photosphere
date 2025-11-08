//
// A fatal error that should be reported to the user without stack traces or technical details.
// This is for user-facing errors that are expected and should be displayed cleanly.
//
export class FatalError extends Error {
    constructor(message: string) {
        super(message);
        this.name = 'FatalError';
        // Maintains proper stack trace for where our error was thrown (only available on V8)
        if (Error.captureStackTrace) {
            Error.captureStackTrace(this, FatalError);
        }
    }
}

