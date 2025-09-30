import * as fs from "fs-extra";
import * as path from "path";
import { log } from "utils";

// Write lock timeout in milliseconds (10 seconds)
const WRITE_LOCK_TIMEOUT_MS = 10000;

//
// Information about a write lock.
//
export interface IWriteLockInfo {
    //
    // The owner of the lock.
    //
    owner: string;

    //
    // The time when the lock was acquired.
    //
    acquiredAt: Date;

    //
    // The unix timestamp when the lock was acquired.
    //
    timestamp: number;
}

//
// Interface for a write lock that can be refreshed and released.
//
export interface ILock {
    //
    // Refreshes the write lock, updating its timestamp.
    // Throws an error if the lock is no longer owned by this lock instance.
    //
    refresh(): Promise<void>;

    //
    // Releases the write lock.
    //
    release(): Promise<void>;
}

//
// Implementation of a file-based write lock.
//
class FileLock implements ILock {
    constructor(
        private readonly filePath: string,
        private readonly owner: string
    ) {}

    async refresh(): Promise<void> {
        const timestamp = Date.now();
        const processId = process.pid;
        
        if (log.verboseEnabled) {
            log.verbose(`[LOCK] ${timestamp},REFRESH_ATTEMPT,${processId},${this.owner},${this.filePath}`);
        }
        
        try {
            // Check if lock exists and we own it
            const existingLock = await checkWriteLock(this.filePath);
            if (!existingLock) {
                throw new Error(`Cannot refresh write lock: lock does not exist for ${this.filePath}`);
            }
            
            if (existingLock.owner !== this.owner) {
                throw new Error(`Cannot refresh write lock: lock is owned by ${existingLock.owner}, not ${this.owner} for ${this.filePath}`);
            }
            
            // Check if lock has timed out
            const lockAge = timestamp - existingLock.timestamp;
            if (lockAge > WRITE_LOCK_TIMEOUT_MS) {
                throw new Error(`Cannot refresh write lock: lock has timed out (age: ${lockAge}ms) for ${this.filePath}`);
            }
            
            // Update the lock with new timestamp
            const lockInfo = {
                owner: this.owner,
                acquiredAt: new Date().toISOString(),
                timestamp
            };
            await fs.writeFile(this.filePath, JSON.stringify(lockInfo));
            
            if (log.verboseEnabled) {
                log.verbose(`[LOCK] ${timestamp},REFRESH_SUCCESS,${processId},${this.owner},${this.filePath}`);
            }
        } catch (err: any) {
            if (log.verboseEnabled) {
                log.verbose(`[LOCK] ${timestamp},REFRESH_FAILED,${processId},${this.owner},${this.filePath},error:${err.message}`);
            }
            throw err;
        }
    }

    async release(): Promise<void> {
        if (log.verboseEnabled) {
            log.verbose(`[LOCK] ${Date.now()},RELEASE_SUCCESS,${process.pid},${this.owner},${this.filePath}`);
        }
        
        try {
            await fs.unlink(this.filePath);
        } catch (err) {
            // Ignore errors if the lock file doesn't exist
        }
    }
}

//
// Checks if a write lock is acquired for the specified file.
// Returns the lock information if it exists, undefined otherwise.
//
export async function checkWriteLock(filePath: string): Promise<IWriteLockInfo | undefined> {
    try {
        if (await fs.pathExists(filePath)) {
            const lockContent = await fs.readFile(filePath, 'utf8');
            const lockData = JSON.parse(lockContent.trim());
            return {
                owner: lockData.owner,
                acquiredAt: new Date(lockData.acquiredAt),
                timestamp: lockData.timestamp
            };
        }
        return undefined;
    } catch (err) {
        return undefined;
    }
}

//
// Attempts to acquire a write lock for the specified file.
// Returns an ILock object if the lock was acquired, undefined if it already exists.
//
export async function acquireWriteLock(filePath: string, owner: string): Promise<ILock | undefined> {
    const timestamp = Date.now();
    const processId = process.pid;
    
    if (log.verboseEnabled) {
        log.verbose(`[LOCK] ${timestamp},ACQUIRE_ATTEMPT,${processId},${owner},${filePath}`);
    }
    
    try {
        // Check if lock already exists
        if (await fs.pathExists(filePath)) {
            // Check if existing lock has timed out (10 seconds = 10000ms)
            const existingLock = await checkWriteLock(filePath);
            if (existingLock) {
                const lockAge = timestamp - existingLock.timestamp;
                if (lockAge > WRITE_LOCK_TIMEOUT_MS) {
                    // Lock has timed out, remove it and proceed to acquire new lock
                    if (log.verboseEnabled) {
                        log.verbose(`[LOCK] ${timestamp},ACQUIRE_TIMEOUT_BREAK,${processId},${owner},${filePath},age:${lockAge}ms,oldOwner:${existingLock.owner}`);
                    }
                    await fs.remove(filePath);
                } else {
                    // Lock is still valid
                    if (log.verboseEnabled) {
                        log.verbose(`[LOCK] ${timestamp},ACQUIRE_FAILED_EXISTS,${processId},${owner},${filePath},age:${lockAge}ms,owner:${existingLock.owner}`);
                    }
                    return undefined;
                }
            } else {
                // Corrupted lock file, remove it
                if (log.verboseEnabled) {
                    log.verbose(`[LOCK] ${timestamp},ACQUIRE_CORRUPTED_BREAK,${processId},${owner},${filePath}`);
                }
                await fs.remove(filePath);
            }
        }
        
        // Ensure directory exists
        await fs.ensureDir(path.dirname(filePath));
        
        // Create lock file with owner and timestamp information
        const lockInfo = {
            owner,
            acquiredAt: new Date().toISOString(),
            timestamp
        };
        await fs.writeFile(filePath, JSON.stringify(lockInfo), { flag: 'wx' }); // 'wx' flag fails if file exists
        
        if (log.verboseEnabled) {
            log.verbose(`[LOCK] ${timestamp},ACQUIRE_SUCCESS,${processId},${owner},${filePath}`);
        }
        
        return new FileLock(filePath, owner);
    } catch (err: any) {
        // If file already exists (EEXIST), return undefined
        if (err.code === 'EEXIST') {
            if (log.verboseEnabled) {
                log.verbose(`[LOCK] ${timestamp},ACQUIRE_FAILED_RACE,${processId},${owner},${filePath}`);
            }
            return undefined;
        }
        if (log.verboseEnabled) {
            log.verbose(`[LOCK] ${timestamp},ACQUIRE_FAILED_ERROR,${processId},${owner},${filePath},error:${err.message}`);
        }
        throw err;
    }
}