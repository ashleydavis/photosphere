//
// The message to show in a LAN share/receive dialog for a caught task failure, using the error's
// own message where it has one and falling back to a generic message otherwise.
//
export function lanShareErrorMessage(error: Error): string {
    if (error.message) {
        return error.message;
    }
    return "LAN share failed. Please try again.";
}
