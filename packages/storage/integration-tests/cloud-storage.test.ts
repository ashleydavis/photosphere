import { CloudStorage } from '../src/lib/cloud-storage';
import { IWriteLockInfo } from '../src/lib/storage';

// These tests require AWS credentials and an S3 bucket to run
// Set the following environment variables before running:
// AWS_ACCESS_KEY_ID=your_access_key
// AWS_SECRET_ACCESS_KEY=your_secret_key  
// AWS_DEFAULT_REGION=your_region (e.g., us-east-1)
// AWS_ENDPOINT=your_endpoint (optional, for S3-compatible services)
// TEST_S3_BUCKET=your_test_bucket_name

describe('CloudStorage Tests', () => {
    let storage: CloudStorage;
    let bucketName: string;
    let location: string;
    const testPrefix = `test-${Date.now()}-${Math.random().toString(36).substring(7)}`;
    
    beforeAll(() => {
        // Check for required environment variables
        const requiredEnvVars = ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'TEST_S3_BUCKET'];
        for (const envVar of requiredEnvVars) {
            if (!process.env[envVar]) {
                throw new Error(`Missing required environment variable: ${envVar}`);
            }
        }
        
        bucketName = process.env.TEST_S3_BUCKET!;
        location = `${bucketName}/${testPrefix}`;
        
        storage = new CloudStorage(location);
    });

    describe('Basic File Operations', () => {
        const testDir = 'basic-file-ops';
        const testContent = Buffer.from('Hello, CloudStorage!', 'utf8');

        it('should write and read a file', async () => {
            const testFile = `${location}/${testDir}/write-read-test.txt`;
            await storage.write(testFile, 'text/plain', testContent);
            
            const readContent = await storage.read(testFile);
            expect(readContent).toEqual(testContent);
        });

        it('should check if file exists', async () => {
            const existingFile = `${location}/${testDir}/exists-test.txt`;
            await storage.write(existingFile, 'text/plain', testContent);
            
            expect(await storage.fileExists(existingFile)).toBe(true);
            expect(await storage.fileExists(`${location}/${testDir}/non-existent-file.txt`)).toBe(false);
        });

        it('should get file info', async () => {
            const testFile = `${location}/${testDir}/info-test.txt`;
            await storage.write(testFile, 'text/plain', testContent);
            
            const info = await storage.info(testFile);
            expect(info).toBeDefined();
            expect(info!.contentType).toBe('text/plain');
            expect(info!.length).toBe(testContent.length);
            expect(info!.lastModified).toBeInstanceOf(Date);
        });

        it('should delete a file', async () => {
            const testFile = `${location}/${testDir}/delete-test.txt`;
            await storage.write(testFile, 'text/plain', testContent);
            
            await storage.deleteFile(testFile);
            expect(await storage.fileExists(testFile)).toBe(false);
        });

        it('should return undefined for non-existent file', async () => {
            const content = await storage.read(`${location}/${testDir}/non-existent.txt`);
            expect(content).toBeUndefined();
            
            const info = await storage.info(`${location}/${testDir}/non-existent.txt`);
            expect(info).toBeUndefined();
        });
    });

    describe('Directory Operations', () => {
        const baseTestDir = 'dir-ops';
        const testFiles = ['file1.txt', 'file2.txt', 'file3.txt'];

        // Each test gets its own subdirectory to avoid conflicts
        const getTestDir = (testName: string) => `${baseTestDir}/${testName}`;

        afterEach(async () => {
            // No cleanup - leave test artifacts for inspection
        });

        it('should check if directory exists', async () => {
            const testDir = getTestDir('exists-test');
            
            // Create files to make directory exist
            for (const file of testFiles) {
                await storage.write(`${location}/${testDir}/${file}`, 'text/plain', Buffer.from(`Content of ${file}`, 'utf8'));
            }
            
            expect(await storage.dirExists(`${location}/${testDir}`)).toBe(true);
            expect(await storage.dirExists(`${location}/${baseTestDir}/non-existent-dir`)).toBe(false);
        });

        it('should check if directory is empty', async () => {
            const testDir = getTestDir('empty-test');
            const emptyDir = getTestDir('empty-dir');
            
            // Create files in testDir
            for (const file of testFiles) {
                await storage.write(`${location}/${testDir}/${file}`, 'text/plain', Buffer.from(`Content of ${file}`, 'utf8'));
            }
            
            expect(await storage.isEmpty(`${location}/${testDir}`)).toBe(false);
            
            // Create and test empty directory
            await storage.write(`${location}/${emptyDir}/temp.txt`, 'text/plain', Buffer.from('temp', 'utf8'));
            await storage.deleteFile(`${location}/${emptyDir}/temp.txt`);
            expect(await storage.isEmpty(`${location}/${emptyDir}`)).toBe(true);
        });

        it('should list files in directory', async () => {
            const testDir = getTestDir('list-files');
            
            // Create test files
            for (const file of testFiles) {
                await storage.write(`${location}/${testDir}/${file}`, 'text/plain', Buffer.from(`Content of ${file}`, 'utf8'));
            }
            
            const result = await storage.listFiles(`${location}/${testDir}`, 10);
            expect(result.names).toHaveLength(3);
            expect(result.names.sort()).toEqual(testFiles.sort());
        });

        it('should list directories', async () => {
            const testDir = getTestDir('list-dirs');
            
            // Create subdirectories
            await storage.write(`${location}/${testDir}/subdir1/file.txt`, 'text/plain', Buffer.from('content', 'utf8'));
            await storage.write(`${location}/${testDir}/subdir2/file.txt`, 'text/plain', Buffer.from('content', 'utf8'));
            
            const result = await storage.listDirs(`${location}/${testDir}`, 10);
            expect(result.names).toHaveLength(2);
            expect(result.names.sort()).toEqual(['subdir1', 'subdir2']);
        });

        it('should delete directory and all contents', async () => {
            const testDir = getTestDir('delete-dir');
            
            // Create test files
            for (const file of testFiles) {
                await storage.write(`${location}/${testDir}/${file}`, 'text/plain', Buffer.from(`Content of ${file}`, 'utf8'));
            }
            
            await storage.deleteDir(`${location}/${testDir}`);
            expect(await storage.dirExists(`${location}/${testDir}`)).toBe(false);
            
            for (const file of testFiles) {
                expect(await storage.fileExists(`${location}/${testDir}/${file}`)).toBe(false);
            }
        });
    });

    describe('Stream Operations', () => {
        const testDir = 'stream-ops';
        const testContent = Buffer.from('Stream test content', 'utf8');

        it('should write and read streams', async () => {
            const testFile = `${testDir}/stream-test.txt`;
            
            // Create a readable stream from buffer
            const { Readable } = await import('stream');
            const readableStream = new Readable({
                read() {
                    this.push(testContent);
                    this.push(null);
                }
            });

            await storage.writeStream(`${location}/${testFile}`, 'text/plain', readableStream, testContent.length);
            
            const stream = storage.readStream(`${location}/${testFile}`);
            const chunks: Buffer[] = [];
            
            await new Promise<void>((resolve, reject) => {
                stream.on('data', chunk => chunks.push(chunk));
                stream.on('end', () => resolve());
                stream.on('error', reject);
            });
            
            const result = Buffer.concat(chunks);
            expect(result).toEqual(testContent);
            
            // Leave stream test file for inspection
        });
    });

    describe('Write Lock Operations', () => {
        const lockDir = 'write-locks';
        const owner1 = 'user-123';
        const owner2 = 'user-456';
        
        // Helper to create unique lock file names for each test
        const getLockFile = (testName: string, lockNum: number = 1) => `${lockDir}/${testName}/lock-${lockNum}.lock`;

        afterEach(async () => {
            // Leave lock files for inspection - no cleanup
            // Note: Some tests may have already released locks as part of their flow
        });

        describe('checkWriteLock', () => {
            it('should return undefined for non-existent lock', async () => {
                const lockFile = getLockFile('check-nonexistent');
                const lockInfo = await storage.checkWriteLock(`${location}/${lockFile}`);
                expect(lockInfo).toBeUndefined();
            });

            it('should return lock info for existing lock', async () => {
                const lockFile = getLockFile('check-existing');
                const beforeTime = new Date();
                await storage.acquireWriteLock(`${location}/${lockFile}`, owner1);
                const afterTime = new Date();
                
                const lockInfo = await storage.checkWriteLock(`${location}/${lockFile}`);
                expect(lockInfo).toBeDefined();
                expect(lockInfo!.owner).toBe(owner1);
                expect(lockInfo!.acquiredAt).toBeInstanceOf(Date);
                expect(lockInfo!.acquiredAt.getTime()).toBeGreaterThanOrEqual(beforeTime.getTime());
                expect(lockInfo!.acquiredAt.getTime()).toBeLessThanOrEqual(afterTime.getTime());
            });
        });

        describe('acquireWriteLock', () => {
            it('should successfully acquire a lock for new file', async () => {
                const lockFile = getLockFile('acquire-new');
                const result = await storage.acquireWriteLock(`${location}/${lockFile}`, owner1);
                expect(result).toBe(true);
                
                // Verify lock was created
                expect(await storage.fileExists(`${location}/${lockFile}`)).toBe(true);
                
                // Verify lock content
                const lockInfo = await storage.checkWriteLock(`${location}/${lockFile}`);
                expect(lockInfo!.owner).toBe(owner1);
                expect(lockInfo!.acquiredAt).toBeInstanceOf(Date);
            });

            it('should fail to acquire lock if one already exists', async () => {
                const lockFile = getLockFile('acquire-existing');
                const firstResult = await storage.acquireWriteLock(`${location}/${lockFile}`, owner1);
                expect(firstResult).toBe(true);
                
                const secondResult = await storage.acquireWriteLock(`${location}/${lockFile}`, owner2);
                expect(secondResult).toBe(false);
                
                // Verify original lock is unchanged
                const lockInfo = await storage.checkWriteLock(`${location}/${lockFile}`);
                expect(lockInfo!.owner).toBe(owner1);
            });

            it('should handle concurrent lock attempts atomically', async () => {
                const lockFile = getLockFile('concurrent-test');
                
                // Create multiple concurrent attempts with different timing mechanisms to simulate real race conditions
                const promises = [
                    // Immediate execution
                    new Promise<{ success: boolean, owner: string }>((resolve) => {
                        setImmediate(async () => {
                            const success = await storage.acquireWriteLock(`${location}/${lockFile}`, 'user-a');
                            resolve({ success, owner: 'user-a' });
                        });
                    }),
                    // Next tick
                    new Promise<{ success: boolean, owner: string }>((resolve) => {
                        process.nextTick(async () => {
                            const success = await storage.acquireWriteLock(`${location}/${lockFile}`, 'user-b');
                            resolve({ success, owner: 'user-b' });
                        });
                    }),
                    // Minimal timeout
                    new Promise<{ success: boolean, owner: string }>((resolve) => {
                        setTimeout(async () => {
                            const success = await storage.acquireWriteLock(`${location}/${lockFile}`, 'user-c');
                            resolve({ success, owner: 'user-c' });
                        }, 0);
                    }),
                    // Immediate with Promise.resolve
                    Promise.resolve().then(async () => {
                        const success = await storage.acquireWriteLock(`${location}/${lockFile}`, 'user-d');
                        return { success, owner: 'user-d' };
                    }),
                    // Direct promise
                    (async () => {
                        const success = await storage.acquireWriteLock(`${location}/${lockFile}`, 'user-e');
                        return { success, owner: 'user-e' };
                    })()
                ];
                
                const results = await Promise.all(promises);
                
                // Exactly one should succeed
                const successfulAttempts = results.filter(r => r.success);
                expect(successfulAttempts.length).toBe(1);
                
                // All others should fail
                const failedAttempts = results.filter(r => !r.success);
                expect(failedAttempts.length).toBe(4);
                
                // Verify lock exists
                expect(await storage.fileExists(`${location}/${lockFile}`)).toBe(true);
                
                // Verify lock has the correct owner
                const lockInfo = await storage.checkWriteLock(`${location}/${lockFile}`);
                expect(lockInfo).toBeDefined();
                expect(lockInfo!.owner).toBe(successfulAttempts[0].owner);
            });

            it('should handle aggressive race conditions with many concurrent attempts', async () => {
                const lockFile = getLockFile('aggressive-race');
                const numAttempts = 20;
                
                // Create many concurrent attempts with various timing mechanisms
                const promises = Array.from({ length: numAttempts }, (_, i) => {
                    const owner = `user-${i}`;
                    
                    return new Promise<{ success: boolean, owner: string }>((resolve) => {
                        // Use different timing mechanisms to create true concurrency
                        if (i % 4 === 0) {
                            // Immediate execution
                            setImmediate(async () => {
                                const success = await storage.acquireWriteLock(`${location}/${lockFile}`, owner);
                                resolve({ success, owner });
                            });
                        } else if (i % 4 === 1) {
                            // Next tick
                            process.nextTick(async () => {
                                const success = await storage.acquireWriteLock(`${location}/${lockFile}`, owner);
                                resolve({ success, owner });
                            });
                        } else if (i % 4 === 2) {
                            // Minimal timeout with tiny random delay
                            setTimeout(async () => {
                                const success = await storage.acquireWriteLock(`${location}/${lockFile}`, owner);
                                resolve({ success, owner });
                            }, Math.random() * 2); // 0-2ms
                        } else {
                            // Promise.resolve chain
                            Promise.resolve().then(async () => {
                                const success = await storage.acquireWriteLock(`${location}/${lockFile}`, owner);
                                resolve({ success, owner });
                            });
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
                const lockInfo = await storage.checkWriteLock(`${location}/${lockFile}`);
                expect(lockInfo).toBeDefined();
                expect(lockInfo!.owner).toBe(successfulAttempts[0].owner);
                
                // Verify only one lock file exists
                expect(await storage.fileExists(`${location}/${lockFile}`)).toBe(true);
            });

            it('should handle repeated race condition tests', async () => {
                // Run multiple rounds of race condition tests to increase chance of catching timing bugs
                const numRounds = 5;
                
                for (let round = 0; round < numRounds; round++) {
                    const lockFile = getLockFile(`race-round-${round}`);
                    const numAttempts = 10;
                    
                    // Create concurrent attempts for this round
                    const promises = Array.from({ length: numAttempts }, (_, i) => {
                        const owner = `round${round}-user${i}`;
                        
                        return new Promise<{ success: boolean, owner: string }>((resolve) => {
                            // Add small random delays to create realistic race conditions
                            const delay = Math.random() * 3; // 0-3ms
                            
                            setTimeout(async () => {
                                try {
                                    const success = await storage.acquireWriteLock(`${location}/${lockFile}`, owner);
                                    resolve({ success, owner });
                                } catch (error) {
                                    // In case of any unexpected errors, treat as failure
                                    resolve({ success: false, owner });
                                }
                            }, delay);
                        });
                    });
                    
                    const results = await Promise.all(promises);
                    
                    // Exactly one should succeed in each round
                    const successfulAttempts = results.filter(r => r.success);
                    expect(successfulAttempts.length).toBe(1);
                    
                    // Verify the winner has a valid lock
                    const lockInfo = await storage.checkWriteLock(`${location}/${lockFile}`);
                    expect(lockInfo).toBeDefined();
                    expect(lockInfo!.owner).toBe(successfulAttempts[0].owner);
                }
            });

            it('should store valid JSON with owner and timestamp', async () => {
                const lockFile = getLockFile('json-format');
                await storage.acquireWriteLock(`${location}/${lockFile}`, owner1);
                
                const content = await storage.read(`${location}/${lockFile}`);
                expect(content).toBeDefined();
                
                const lockData = JSON.parse(content!.toString('utf8'));
                expect(lockData).toHaveProperty('owner');
                expect(lockData).toHaveProperty('acquiredAt');
                expect(typeof lockData.owner).toBe('string');
                expect(typeof lockData.acquiredAt).toBe('string');
                
                // Verify it's a valid ISO date string
                const date = new Date(lockData.acquiredAt);
                expect(date.toISOString()).toBe(lockData.acquiredAt);
            });
        });

        describe('releaseWriteLock', () => {
            it('should successfully release an existing lock', async () => {
                const lockFile = getLockFile('release-existing');
                await storage.acquireWriteLock(`${location}/${lockFile}`, owner1);
                expect(await storage.checkWriteLock(`${location}/${lockFile}`)).toBeDefined();
                
                await storage.releaseWriteLock(`${location}/${lockFile}`);
                expect(await storage.checkWriteLock(`${location}/${lockFile}`)).toBeUndefined();
                expect(await storage.fileExists(`${location}/${lockFile}`)).toBe(false);
            });

            it('should handle releasing non-existent lock gracefully', async () => {
                const lockFile = getLockFile('release-nonexistent');
                await expect(storage.releaseWriteLock(`${location}/${lockFile}`))
                    .resolves.toBeUndefined();
            });

            it('should allow reacquisition after release', async () => {
                const lockFile = getLockFile('reacquire-after-release');
                // Acquire, release, then acquire again
                expect(await storage.acquireWriteLock(`${location}/${lockFile}`, owner1)).toBe(true);
                await storage.releaseWriteLock(`${location}/${lockFile}`);
                expect(await storage.acquireWriteLock(`${location}/${lockFile}`, owner2)).toBe(true);
                
                // Verify new owner
                const lockInfo = await storage.checkWriteLock(`${location}/${lockFile}`);
                expect(lockInfo!.owner).toBe(owner2);
            });
        });

        describe('lock file format and metadata', () => {
            it('should create lock files with correct content type', async () => {
                const lockFile = getLockFile('content-type');
                await storage.acquireWriteLock(`${location}/${lockFile}`, owner1);
                
                const info = await storage.info(`${location}/${lockFile}`);
                expect(info!.contentType).toBe('application/json');
            });

            it('should handle special characters in owner names', async () => {
                const lockFile = getLockFile('special-chars');
                const specialOwner = 'user@domain.com with spaces & symbols!';
                
                await storage.acquireWriteLock(`${location}/${lockFile}`, specialOwner);
                
                const lockInfo = await storage.checkWriteLock(`${location}/${lockFile}`);
                expect(lockInfo!.owner).toBe(specialOwner);
            });

            it('should preserve lock timing information accurately', async () => {
                const lockFile = getLockFile('timing');
                const beforeTime = Date.now();
                await storage.acquireWriteLock(`${location}/${lockFile}`, owner1);
                const afterTime = Date.now();
                
                const lockInfo = await storage.checkWriteLock(`${location}/${lockFile}`);
                const lockTime = lockInfo!.acquiredAt.getTime();
                
                expect(lockTime).toBeGreaterThanOrEqual(beforeTime);
                expect(lockTime).toBeLessThanOrEqual(afterTime);
            });
        });

        describe('full lock lifecycle', () => {
            it('should handle complete lock workflow', async () => {
                const lockFile = getLockFile('full-lifecycle');
                // 1. No lock initially
                expect(await storage.checkWriteLock(`${location}/${lockFile}`)).toBeUndefined();
                
                // 2. Acquire lock
                expect(await storage.acquireWriteLock(`${location}/${lockFile}`, owner1)).toBe(true);
                
                // 3. Verify lock exists and has correct details
                const lockInfo = await storage.checkWriteLock(`${location}/${lockFile}`);
                expect(lockInfo!.owner).toBe(owner1);
                expect(lockInfo!.acquiredAt).toBeInstanceOf(Date);
                
                // 4. Other processes cannot acquire lock
                expect(await storage.acquireWriteLock(`${location}/${lockFile}`, owner2)).toBe(false);
                
                // 5. Release lock
                await storage.releaseWriteLock(`${location}/${lockFile}`);
                
                // 6. Lock is gone
                expect(await storage.checkWriteLock(`${location}/${lockFile}`)).toBeUndefined();
                
                // 7. Other processes can now acquire lock
                expect(await storage.acquireWriteLock(`${location}/${lockFile}`, owner2)).toBe(true);
            });
        });
    });

    describe('Error Handling', () => {
        const errorTestDir = 'error-handling';

        it('should handle invalid bucket/key combinations', async () => {
            const invalidLocation = 'invalid-bucket-name-that-does-not-exist';
            const invalidStorage = new CloudStorage(invalidLocation);

            await expect(invalidStorage.write(`${invalidLocation}/${errorTestDir}/invalid-bucket-test.txt`, 'text/plain', Buffer.from('test', 'utf8')))
                .rejects.toThrow();
        });

        it('should handle readonly mode', async () => {
            const readonlyStorage = new CloudStorage(`${bucketName}/${testPrefix}`, true, {
                accessKeyId: process.env.AWS_ACCESS_KEY_ID!,
                secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY!,
                region: process.env.AWS_REGION
            }, true);

            await expect(readonlyStorage.write(`${location}/${errorTestDir}/readonly-test.txt`, 'text/plain', Buffer.from('test', 'utf8')))
                .rejects.toThrow('Cannot perform write file operation: storage is in readonly mode');

            await expect(readonlyStorage.acquireWriteLock(`${location}/${errorTestDir}/readonly-test.lock`, 'user'))
                .rejects.toThrow('Cannot perform acquire write lock operation: storage is in readonly mode');

            await expect(readonlyStorage.releaseWriteLock(`${location}/${errorTestDir}/readonly-test.lock`))
                .rejects.toThrow('Cannot perform release write lock operation: storage is in readonly mode');
        });
    });

    describe('Path Handling', () => {
        const pathTestDir = 'path-handling';

        it('should handle various path formats correctly', async () => {
            const testCases = [
                'simple-file.txt',
                'path/with/slashes.txt',
                'path/with spaces/file.txt',
                'path/with-special_chars@123.txt'
            ];

            for (const testPath of testCases) {
                const fullPath = `${location}/${pathTestDir}/various-formats/${testPath}`;
                const content = Buffer.from(`Content for ${testPath}`, 'utf8');
                
                await storage.write(fullPath, 'text/plain', content);
                const readContent = await storage.read(fullPath);
                expect(readContent).toEqual(content);
                
                await storage.deleteFile(fullPath);
            }
        });
    });
});