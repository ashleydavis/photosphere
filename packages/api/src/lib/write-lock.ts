import { IStorage } from "storage";
import { log, retry, sleep } from "utils";

//
// How long one request against the lock file may take before it is retried.
//
// Thirty seconds, the retry default, is a desktop's idea of a long time. The lock file lives beside
// the database, so on a phone syncing to S3 it is a network request queued behind whatever else that
// connection is carrying. Every background sync pass on a Pixel 6 died with "Operation timed out
// after 30000ms: () => rawStorage.releaseWriteLock(...)", thrown from the release in a finally
// block, which killed the pass before it reached the half that pushes files. The library never went
// up, and the reason was the lock being let go of rather than anything to do with the photos.
//
const LOCK_REQUEST_TIMEOUT_MS = 5 * 60 * 1000;

//
// Acquires the write lock for the database.
// Only needed for writing to:
// - the merkle tree file (files.dat).
// - the BSON database and sorted indexes.
//
// Throws when the write lock cannot be acquired.
//
export async function acquireWriteLock(rawStorage: IStorage, sessionId: string, maxAttempts: number = 3): Promise<boolean> {

    const lockFilePath = ".db/write.lock";
    
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
        const haveWriteLock = await rawStorage.acquireWriteLock(lockFilePath, sessionId);
        if (haveWriteLock) {
            // We have the write lock.
            return true;
        }
        
        // Wait with increasing timeout before next attempt (unless this is the last attempt).
        if (attempt < maxAttempts) {
            const timeoutMs = attempt * 1000; // 1s, 2s
            await sleep(timeoutMs);
        }
    }
    
    // All attempts failed - check lock info for detailed error message.
    const lockInfo = await rawStorage.checkWriteLock(lockFilePath);
    if (lockInfo) {
        const timeSinceLocked = Date.now() - lockInfo.acquiredAt.getTime();
        const timeString = timeSinceLocked < 60000 
            ? `${Math.round(timeSinceLocked / 1000)}s`
            : `${Math.round(timeSinceLocked / 60000)}m`;
        
        log.warn(
            `Failed to acquire write lock after ${maxAttempts} attempts. ` +
            `Lock is currently held by "${lockInfo.owner}" since ${timeString} ago ` +
            `(acquired at ${lockInfo.acquiredAt.toISOString()}).`
        );
    } 
    else {
        log.warn(
            `Failed to acquire write lock after ${maxAttempts} attempts. ` +
            `Lock appears to be available but acquisition failed.`
        );
    }

    return false;
}

//
// Refreshes the write lock to prevent timeout.
//
export async function refreshWriteLock(rawStorage: IStorage, sessionId: string): Promise<void> {
    await retry(() => rawStorage.refreshWriteLock(".db/write.lock", sessionId), 3, 1_000, 2, LOCK_REQUEST_TIMEOUT_MS,
        "Failed to refresh the database write lock");
}

//
// Releases the write lock for the database.
//
export async function releaseWriteLock(rawStorage: IStorage): Promise<void> {
    await retry(() => rawStorage.releaseWriteLock(".db/write.lock"), 3, 1_000, 2, LOCK_REQUEST_TIMEOUT_MS,
        "Failed to release the database write lock");
}
