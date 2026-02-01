import { IStorage } from "storage";
import { log, retry, sleep } from "utils";

//
// Acquires the write lock for the database.
// Only needed for writing to:
// - the merkle tree file (files.dat).
// - the BSON database and sorted indexes.
//
// Throws when the write lock cannot be acquired.
//
export async function acquireWriteLock(metadataStorage: IStorage, sessionId: string, maxAttempts: number = 3): Promise<boolean> {
    
    const lockFilePath = ".db/write.lock";
    
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
        const haveWriteLock = await metadataStorage.acquireWriteLock(lockFilePath, sessionId);
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
    const lockInfo = await metadataStorage.checkWriteLock(lockFilePath);
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
export async function refreshWriteLock(metadataStorage: IStorage, sessionId: string): Promise<void> {
    await retry(() => metadataStorage.refreshWriteLock(".db/write.lock", sessionId));
}

//
// Releases the write lock for the database.
//
export async function releaseWriteLock(metadataStorage: IStorage): Promise<void> {
    await retry(() => metadataStorage.releaseWriteLock(".db/write.lock"));
}
