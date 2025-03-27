
//
// An error that wraps another error to include the original cause.
//
export class WrappedError extends Error {
    constructor(message: string, public options: { cause: Error }) {
        super(message);
    }
}