
//
// Timeout for retrying operations that stream large files (e.g. videos) to/from S3.
//
export const LARGE_FILE_TIMEOUT = 90 * 60 * 1_000;

//
// How long to wait to find out whether a database is reachable at all, in milliseconds.
//
// This bounds one small read, not a transfer: whether a merkle tree is there. It exists because the
// S3 client's own request ceiling is ten minutes, which is right for a phone pushing a 200 MB video
// through the engine bridge and hopeless for a user opening a database. Nothing else bounded that
// read, so an unreachable bucket left the app on a screen that never resolved.
//
// A phone reaches a stopped server as a connection that is accepted and then answers nothing (an
// `adb reverse` forward with nothing behind it does exactly that), so the client's ten second connect
// timeout never fires and only this one ends the wait. Measured against a Pixel 6 with the server
// stopped: with no bound the app said nothing for the 300 seconds it was watched for, and with this
// one it reports the bucket unreachable inside half a minute.
//
export const DATABASE_REACHABLE_TIMEOUT = 30 * 1_000;
