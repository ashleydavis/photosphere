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

//
// The message a receive dialog shows when the receive ended with nothing. A device that was heard looking for a different
// pairing code means the code was mistyped, which is a different thing to tell a person from nobody sharing at all.
//
export function noSenderMessage(sawMismatchedSender: boolean): string {
    if (sawMismatchedSender) {
        return "No sender connected within 60 seconds. A device was found, but it is using a different pairing code.";
    }
    return "No sender connected within 60 seconds.";
}

//
// The message a share dialog shows when no receiver was found, telling a receiver heard with a different pairing code apart
// from no receiver at all.
//
export function noReceiverMessage(sawMismatchedReceiver: boolean): string {
    if (sawMismatchedReceiver) {
        return "No receiver found within 60 seconds. A device was found, but it is using a different pairing code.";
    }
    return "No receiver found within 60 seconds.";
}
