import * as fs from 'fs/promises';
import * as path from 'path';
import { FileStorage } from '../lib/file-storage';
import { ensureDir, remove, pathExists } from 'node-utils';

describe('FileStorage Write Locks', () => {
    let tempDir: string;
    let storage: FileStorage;

    beforeEach(async () => {
        // Use a unique temp directory for each test
        tempDir = path.join(__dirname, `temp-test-locks-${Date.now()}-${Math.random()}`);
        await ensureDir(tempDir);
        storage = new FileStorage(tempDir);
    });

    afterEach(async () => {
        // Clean up all lock files first
        try {
            const files = await fs.readdir(tempDir, { recursive: true });
            for (const file of files) {
                if (typeof file === 'string' && file.endsWith('.lock')) {
                    await remove(path.join(tempDir, file));
                }
            }
        } catch (err) {
            // Ignore cleanup errors
        }
        await remove(tempDir);
    });

    describe('checkWriteLock', () => {
        it('should return undefined for non-existent lock', async () => {
            const filePath = path.join(tempDir, 'test-file-1.txt');
            const lockInfo = await storage.checkWriteLock(filePath);
            expect(lockInfo).toBeUndefined();
        });

        it('should return lock info for existing lock', async () => {
            const owner = 'user123';
            const filePath = path.join(tempDir, 'test-file-2.txt');
            
            await storage.acquireWriteLock(filePath, owner);
            
            const lockInfo = await storage.checkWriteLock(filePath);
            expect(lockInfo).toBeDefined();
            expect(lockInfo!.owner).toBe(owner);
            expect(lockInfo!.acquiredAt).toBeInstanceOf(Date);
        });

        it('should handle corrupted lock files gracefully', async () => {
            const filePath = path.join(tempDir, 'test-file-3.txt');
            const lockFilePath = `${filePath}.lock`;
            
            // Create an invalid JSON lock file
            await ensureDir(path.dirname(lockFilePath));
            await fs.writeFile(lockFilePath, 'invalid json');
            
            const lockInfo = await storage.checkWriteLock(filePath);
            expect(lockInfo).toBeUndefined();
        });

        it('should handle missing lock files gracefully', async () => {
            const filePath = path.join(tempDir, 'non/existent/file-4.txt');
            
            const lockInfo = await storage.checkWriteLock(filePath);
            expect(lockInfo).toBeUndefined();
        });
    });

    describe('acquireWriteLock', () => {
        it('should successfully acquire a lock for new file', async () => {
            const owner = 'user123';
            const lockFilePath = path.join(tempDir, 'test-file-5.txt.lock');
            
            const result = await storage.acquireWriteLock(lockFilePath, owner);
            expect(result).toBe(true);
            
            // Verify lock file was created
            expect(await pathExists(lockFilePath)).toBe(true);
            
            // Verify lock content
            const lockContent = await fs.readFile(lockFilePath, 'utf8');
            const lockData = JSON.parse(lockContent);
            expect(lockData.owner).toBe(owner);
            expect(lockData.acquiredAt).toBeDefined();
        });

        it('should fail to acquire lock if one already exists', async () => {
            const lockFilePath = path.join(tempDir, 'test-file-6.txt.lock');
            
            const firstResult = await storage.acquireWriteLock(lockFilePath, 'user1');
            expect(firstResult).toBe(true);
            
            const secondResult = await storage.acquireWriteLock(lockFilePath, 'user2');
            expect(secondResult).toBe(false);
        });

        it('should create lock file in nested directories', async () => {
            const lockFilePath = path.join(tempDir, 'nested/dir/test-file-7.txt.lock');
            const owner = 'user123';
            
            const result = await storage.acquireWriteLock(lockFilePath, owner);
            expect(result).toBe(true);
            
            expect(await pathExists(lockFilePath)).toBe(true);
        });

        it('should handle race conditions properly', async () => {
            const lockFilePath = path.join(tempDir, 'test-file-8.txt.lock');
            
            // Create multiple storage instances to simulate different processes
            const storage1 = new FileStorage(tempDir);
            const storage2 = new FileStorage(tempDir);
            const storage3 = new FileStorage(tempDir);
            
            // Use setImmediate to force actual concurrency
            const promises = [
                new Promise<boolean>(resolve => setImmediate(() => resolve(storage1.acquireWriteLock(lockFilePath, 'user1')))),
                new Promise<boolean>(resolve => setImmediate(() => resolve(storage2.acquireWriteLock(lockFilePath, 'user2')))),
                new Promise<boolean>(resolve => setImmediate(() => resolve(storage3.acquireWriteLock(lockFilePath, 'user3'))))
            ];
            
            const results = await Promise.all(promises);
            
            // Only one should succeed
            const successCount = results.filter(r => r === true).length;
            expect(successCount).toBe(1);
            
            // Verify only one lock file exists
            expect(await pathExists(lockFilePath)).toBe(true);
            
            // Verify the lock has one of the expected owners
            const lockInfo = await storage.checkWriteLock(lockFilePath);
            expect(lockInfo).toBeDefined();
            expect(['user1', 'user2', 'user3']).toContain(lockInfo!.owner);
        });

        it('should handle aggressive race conditions with many concurrent attempts', async () => {
            const lockFilePath = path.join(tempDir, 'race-test-file.txt.lock');
            const numAttempts = 50;
            
            // Create many storage instances
            const storageInstances = Array.from({ length: numAttempts }, () => new FileStorage(tempDir));
            
            // Create aggressive race condition using various timing mechanisms
            const promises = storageInstances.map((storage, i) => {
                return new Promise<{ success: boolean, owner: string }>((resolve) => {
                    const owner = `user-${i}`;
                    
                    // Use different timing mechanisms to create true concurrency
                    if (i % 3 === 0) {
                        // Immediate execution
                        setImmediate(async () => {
                            const success = await storage.acquireWriteLock(lockFilePath, owner);
                            resolve({ success, owner });
                        });
                    } else if (i % 3 === 1) {
                        // Next tick
                        process.nextTick(async () => {
                            const success = await storage.acquireWriteLock(lockFilePath, owner);
                            resolve({ success, owner });
                        });
                    } else {
                        // Minimal timeout
                        setTimeout(async () => {
                            const success = await storage.acquireWriteLock(lockFilePath, owner);
                            resolve({ success, owner });
                        }, 0);
                    }
                });
            });
            
            const results = await Promise.all(promises);
            
            // Exactly one should succeed
            const successfulAttempts = results.filter(r => r.success);
            expect(successfulAttempts.length).toBe(1);
            
            // All others should fail
            const failedAttempts = results.filter(r => !r.success);
            expect(failedAttempts.length).toBe(numAttempts - 1);
            
            // Verify the lock exists and belongs to the successful user
            const lockInfo = await storage.checkWriteLock(lockFilePath);
            expect(lockInfo).toBeDefined();
            expect(lockInfo!.owner).toBe(successfulAttempts[0].owner);
            
            // Verify only one lock file exists
            expect(await pathExists(lockFilePath)).toBe(true);
        });

        it('should handle race conditions with realistic timing delays', async () => {
            // This test repeats the race condition multiple times to increase
            // the chance of catching timing-related bugs
            const numTests = 10;
            
            for (let testRun = 0; testRun < numTests; testRun++) {
                const lockFilePath = path.join(tempDir, `race-timing-test-${testRun}.txt.lock`);
                const numAttempts = 20;
                
                const storageInstances = Array.from({ length: numAttempts }, () => new FileStorage(tempDir));
                
                // Create race condition with realistic timing variations
                const promises = storageInstances.map((storage, i) => {
                    return new Promise<{ success: boolean, owner: string }>((resolve) => {
                        const owner = `test${testRun}-user${i}`;
                        
                        // Add small random delays to create more realistic race conditions
                        const delay = Math.random() * 2; // 0-2ms random delay
                        
                        setTimeout(async () => {
                            try {
                                const success = await storage.acquireWriteLock(lockFilePath, owner);
                                resolve({ success, owner });
                            } catch (error) {
                                // In case of any unexpected errors, treat as failure
                                resolve({ success: false, owner });
                            }
                        }, delay);
                    });
                });
                
                const results = await Promise.all(promises);
                
                // Exactly one should succeed in each test run
                const successfulAttempts = results.filter(r => r.success);
                expect(successfulAttempts.length).toBe(1);
                
                // Verify the winner has a valid lock
                const lockInfo = await storage.checkWriteLock(lockFilePath);
                expect(lockInfo).toBeDefined();
                expect(lockInfo!.owner).toBe(successfulAttempts[0].owner);
                
                // Clean up for next iteration
                await storage.releaseWriteLock(lockFilePath);
            }
        });

        it('should demonstrate atomic lock file creation prevents race conditions', async () => {
            const lockFilePath = path.join(tempDir, 'atomic-test-file.txt.lock');
            
            // Create a custom test that manually creates lock file to simulate
            // what would happen if two processes tried to create the same lock file
            
            // First process acquires lock normally
            const firstResult = await storage.acquireWriteLock(lockFilePath, 'first-user');
            expect(firstResult).toBe(true);
            
            // Second process tries to acquire - should fail due to existing lock
            const secondResult = await storage.acquireWriteLock(lockFilePath, 'second-user');
            expect(secondResult).toBe(false);
            
            // Verify the first user still owns the lock
            const lockInfo = await storage.checkWriteLock(lockFilePath);
            expect(lockInfo!.owner).toBe('first-user');
            
            // Verify only one lock file exists (no corruption from failed attempts)
            const lockContent = await fs.readFile(lockFilePath, 'utf8');
            const lockData = JSON.parse(lockContent);
            expect(lockData.owner).toBe('first-user');
        });

        it('should store timestamp accurately', async () => {
            const lockFilePath = path.join(tempDir, 'test-file-10.txt.lock');
            const owner = 'user123';
            const beforeTime = new Date();
            
            // Wait a small amount to ensure timestamp precision
            await new Promise(resolve => setTimeout(resolve, 1));
            await storage.acquireWriteLock(lockFilePath, owner);
            await new Promise(resolve => setTimeout(resolve, 1));
            
            const afterTime = new Date();
            const lockInfo = await storage.checkWriteLock(lockFilePath);
            
            expect(lockInfo).toBeDefined();
            expect(lockInfo!.acquiredAt.getTime()).toBeGreaterThanOrEqual(beforeTime.getTime());
            expect(lockInfo!.acquiredAt.getTime()).toBeLessThanOrEqual(afterTime.getTime());
        });
    });

    describe('releaseWriteLock', () => {
        it('should successfully release an existing lock', async () => {
            const lockFilePath = path.join(tempDir, 'test-file-11.txt.lock');
            const owner = 'user123';
            
            await storage.acquireWriteLock(lockFilePath, owner);
            expect(await storage.checkWriteLock(lockFilePath)).toBeDefined();
            
            await storage.releaseWriteLock(lockFilePath);
            expect(await storage.checkWriteLock(lockFilePath)).toBeUndefined();
            
            // Verify lock file was deleted
            expect(await pathExists(lockFilePath)).toBe(false);
        });

        it('should handle releasing non-existent lock gracefully', async () => {
            const lockFilePath = path.join(tempDir, 'non-existent-file-12.txt.lock');
            // Should not throw error
            await expect(storage.releaseWriteLock(lockFilePath))
                .resolves.toBeUndefined();
        });

        it('should allow reacquisition after release', async () => {
            const lockFilePath = path.join(tempDir, 'test-file-14.txt.lock');
            
            // Acquire, release, then acquire again
            expect(await storage.acquireWriteLock(lockFilePath, 'user1')).toBe(true);
            await storage.releaseWriteLock(lockFilePath);
            expect(await storage.acquireWriteLock(lockFilePath, 'user2')).toBe(true);
            
            // Verify new owner
            const lockInfo = await storage.checkWriteLock(lockFilePath);
            expect(lockInfo!.owner).toBe('user2');
        });
    });

    describe('lock file format', () => {
        it('should create valid JSON lock files', async () => {
            const lockFilePath = path.join(tempDir, 'test-file-15.txt.lock');
            const owner = 'user123';
            
            await storage.acquireWriteLock(lockFilePath, owner);
            
            const lockContent = await fs.readFile(lockFilePath, 'utf8');
            
            // Should be valid JSON
            expect(() => JSON.parse(lockContent)).not.toThrow();
            
            const lockData = JSON.parse(lockContent);
            expect(lockData).toHaveProperty('owner');
            expect(lockData).toHaveProperty('acquiredAt');
            expect(typeof lockData.owner).toBe('string');
            expect(typeof lockData.acquiredAt).toBe('string');
            
            // acquiredAt should be a valid ISO date string
            expect(new Date(lockData.acquiredAt).toISOString()).toBe(lockData.acquiredAt);
        });

        it('should handle special characters in owner names', async () => {
            const lockFilePath = path.join(tempDir, 'test-file-16.txt.lock');
            const specialOwner = 'user@domain.com with spaces & symbols!';
            
            await storage.acquireWriteLock(lockFilePath, specialOwner);
            
            const lockInfo = await storage.checkWriteLock(lockFilePath);
            expect(lockInfo!.owner).toBe(specialOwner);
        });
    });

    describe('integration scenarios', () => {
        it('should handle full lock lifecycle', async () => {
            const lockFilePath = path.join(tempDir, 'important-file-17.txt.lock');
            const owner = 'critical-process';
            
            // 1. No lock initially
            expect(await storage.checkWriteLock(lockFilePath)).toBeUndefined();
            
            // 2. Acquire lock
            expect(await storage.acquireWriteLock(lockFilePath, owner)).toBe(true);
            
            // 3. Verify lock exists and has correct details
            const lockInfo = await storage.checkWriteLock(lockFilePath);
            expect(lockInfo!.owner).toBe(owner);
            expect(lockInfo!.acquiredAt).toBeInstanceOf(Date);
            
            // 4. Other processes cannot acquire lock
            expect(await storage.acquireWriteLock(lockFilePath, 'other-process')).toBe(false);
            
            // 5. Release lock
            await storage.releaseWriteLock(lockFilePath);
            
            // 6. Lock is gone
            expect(await storage.checkWriteLock(lockFilePath)).toBeUndefined();
            
            // 7. Other processes can now acquire lock
            expect(await storage.acquireWriteLock(lockFilePath, 'other-process')).toBe(true);
        });

        it('should work with complex file paths', async () => {
            const complexPaths = [
                'simple-18.txt.lock',
                'path/with/slashes-19.txt.lock',
                'path/with spaces/file-20.txt.lock',
                'path/with-special_chars@123-21.txt.lock',
                'very/deep/nested/path/structure/file-22.txt.lock'
            ];
            
            for (const relativePath of complexPaths) {
                const lockFilePath = path.join(tempDir, relativePath);
                const owner = `owner-${relativePath}`;
                
                expect(await storage.acquireWriteLock(lockFilePath, owner)).toBe(true);
                
                const lockInfo = await storage.checkWriteLock(lockFilePath);
                expect(lockInfo!.owner).toBe(owner);
                
                await storage.releaseWriteLock(lockFilePath);
                expect(await storage.checkWriteLock(lockFilePath)).toBeUndefined();
            }
        });
    });
});