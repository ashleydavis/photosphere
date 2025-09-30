import * as fs from "fs-extra";
import * as path from "path";
import * as os from "os";
import { acquireWriteLock, checkWriteLock } from "../lib/write-lock";

describe("Write Lock Module", () => {
    let tempDir: string;
    let lockFilePath: string;

    beforeEach(async () => {
        // Create a temporary directory for testing
        tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "write-lock-test-"));
        lockFilePath = path.join(tempDir, "test.lock");
    });

    afterEach(async () => {
        // Clean up the temporary directory
        await fs.remove(tempDir);
    });

    test("should acquire a write lock successfully", async () => {
        const lock = await acquireWriteLock(lockFilePath, "test-owner");
        expect(lock).toBeDefined();
        
        // Verify lock file exists
        expect(await fs.pathExists(lockFilePath)).toBe(true);
        
        // Clean up
        if (lock) {
            await lock.release();
        }
    });

    test("should return undefined when lock already exists", async () => {
        const lock1 = await acquireWriteLock(lockFilePath, "owner1");
        expect(lock1).toBeDefined();
        
        const lock2 = await acquireWriteLock(lockFilePath, "owner2");
        expect(lock2).toBeUndefined();
        
        // Clean up
        if (lock1) {
            await lock1.release();
        }
    });

    test("should check existing lock", async () => {
        const lock = await acquireWriteLock(lockFilePath, "test-owner");
        expect(lock).toBeDefined();
        
        const lockInfo = await checkWriteLock(lockFilePath);
        expect(lockInfo).toBeDefined();
        expect(lockInfo?.owner).toBe("test-owner");
        
        // Clean up
        if (lock) {
            await lock.release();
        }
    });

    test("should refresh lock successfully", async () => {
        const lock = await acquireWriteLock(lockFilePath, "test-owner");
        expect(lock).toBeDefined();
        
        if (lock) {
            // Should not throw an error
            await lock.refresh();
            await lock.release();
        }
    });

    test("should release lock successfully", async () => {
        const lock = await acquireWriteLock(lockFilePath, "test-owner");
        expect(lock).toBeDefined();
        
        if (lock) {
            await lock.release();
            
            // Verify lock file is gone
            expect(await fs.pathExists(lockFilePath)).toBe(false);
        }
    });

    test("should acquire lock after timeout", async () => {
        // Manually create an expired lock file
        const expiredLockInfo = {
            owner: "expired-owner",
            acquiredAt: new Date(Date.now() - 60000).toISOString(), // 1 minute ago
            timestamp: Date.now() - 60000 // 1 minute ago
        };
        
        await fs.ensureDir(path.dirname(lockFilePath));
        await fs.writeFile(lockFilePath, JSON.stringify(expiredLockInfo));
        
        // Should be able to acquire the lock since it's expired
        const lock = await acquireWriteLock(lockFilePath, "new-owner");
        expect(lock).toBeDefined();
        
        // Clean up
        if (lock) {
            await lock.release();
        }
    });
});