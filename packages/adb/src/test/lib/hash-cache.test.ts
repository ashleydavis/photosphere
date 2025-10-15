import * as crypto from 'crypto';
import { IStorage, IWriteLockInfo } from 'storage';
import { HashCache } from '../../lib/hash-cache';

// Mock implementation of IStorage
class MockStorage implements IStorage {
    private files: Map<string, Buffer> = new Map();
    
    constructor(public readonly location: string = 'mock-storage', public readonly isReadonly: boolean = false) {}
    
    async isEmpty(path: string): Promise<boolean> {
        for (const filePath of this.files.keys()) {
            if (filePath.startsWith(path)) {
                return false;
            }
        }
        return true;
    }
    
    async listFiles(path: string, max: number, next?: string): Promise<{ names: string[], next?: string }> {
        const result: string[] = [];
        for (const filePath of this.files.keys()) {
            if (filePath.startsWith(path)) {
                result.push(filePath.substring(path.length).replace(/^\//, ''));
            }
            if (result.length >= max) {
                break;
            }
        }
        return { names: result };
    }
    
    async listDirs(path: string, max: number, next?: string): Promise<{ names: string[], next?: string }> {
        return { names: [] };
    }
    
    async fileExists(filePath: string): Promise<boolean> {
        return this.files.has(filePath);
    }
    
    async dirExists(dirPath: string): Promise<boolean> {
        return false;
    }
    
    async info(filePath: string): Promise<{ contentType: string | undefined, length: number, lastModified: Date } | undefined> {
        const file = this.files.get(filePath);
        if (!file) {
            return undefined;
        }
        return {
            contentType: 'application/octet-stream',
            length: file.length,
            lastModified: new Date()
        };
    }
    
    async read(filePath: string): Promise<Buffer | undefined> {
        return this.files.get(filePath);
    }
    
    async write(filePath: string, contentType: string | undefined, data: Buffer): Promise<void> {
        this.files.set(filePath, data);
    }
    
    readStream(filePath: string): any {
        throw new Error('Not implemented in mock');
    }
    
    async writeStream(filePath: string, contentType: string | undefined, inputStream: any, contentLength?: number): Promise<void> {
        throw new Error('Not implemented in mock');
    }
    
    async deleteFile(filePath: string): Promise<void> {
        this.files.delete(filePath);
    }
    
    async deleteDir(dirPath: string): Promise<void> {
        // Remove all files that start with dirPath
        for (const filePath of this.files.keys()) {
            if (filePath.startsWith(dirPath)) {
                this.files.delete(filePath);
            }
        }
    }
    
    async copyTo(srcPath: string, destPath: string): Promise<void> {
        const data = this.files.get(srcPath);
        if (data) {
            this.files.set(destPath, data);
        }
    }
    
    async checkWriteLock(filePath: string): Promise<IWriteLockInfo | undefined> {
        return undefined;
    }
    
    async acquireWriteLock(filePath: string, owner: string): Promise<boolean> {
        return true;
    }
    
    async releaseWriteLock(filePath: string): Promise<void> {
        // No-op in mock
    }
    
    async refreshWriteLock(filePath: string, owner: string): Promise<void> {
        // No-op in mock
    }
}

// Helper function to create a file hash
function createHash(content: string): Buffer {
    return crypto.createHash('sha256').update(content).digest();
}

describe('HashCache', () => {
    let mockStorage: MockStorage;
    let hashCache: HashCache;
    const cacheDir = '.db';
    
    beforeEach(() => {
        mockStorage = new MockStorage();
        hashCache = new HashCache(mockStorage, cacheDir);
    });
    
    test('should initialize with empty cache', async () => {
        const loaded = await hashCache.load();
        expect(loaded).toBe(false);
        expect(hashCache.getEntryCount()).toBe(0);
    });
    
    test('should add and retrieve hash', async () => {
        await hashCache.load();
        
        const filePath = 'test/file1.txt';
        const hash = createHash('file content');
        const fileSize = 100;
        const lastModified = new Date();
        
        hashCache.addHash(filePath, { hash, length: fileSize, lastModified });
        
        const retrieved = hashCache.getHash(filePath);
        expect(retrieved).toBeDefined();
        expect(retrieved!.hash.toString('hex')).toBe(hash.toString('hex'));
        expect(retrieved!.length).toBe(fileSize);
        expect(retrieved!.lastModified.getTime()).toBe(lastModified.getTime());
        expect(hashCache.getEntryCount()).toBe(1);
    });
    
    test('should update existing hash', async () => {
        await hashCache.load();
        
        const filePath = 'test/file2.txt';
        const hash1 = createHash('original content');
        const fileSize1 = 100;
        const lastModified1 = new Date(2023, 1, 1);
        
        hashCache.addHash(filePath, { hash: hash1, length: fileSize1, lastModified: lastModified1 });
        
        // Update with new hash
        const hash2 = createHash('updated content');
        const fileSize2 = 200;
        const lastModified2 = new Date(2023, 2, 1);
        
        hashCache.addHash(filePath, { hash: hash2, length: fileSize2, lastModified: lastModified2 });
        
        const retrieved = hashCache.getHash(filePath);
        expect(retrieved).toBeDefined();
        expect(retrieved!.hash.toString('hex')).toBe(hash2.toString('hex'));
        expect(retrieved!.length).toBe(fileSize2);
        expect(retrieved!.lastModified.getTime()).toBe(lastModified2.getTime());
        expect(hashCache.getEntryCount()).toBe(1); // Count should still be 1
    });
    
    test('should save and load cache', async () => {
        await hashCache.load();
        
        // Add some hashes
        const file1 = 'test/file1.txt';
        const hash1 = createHash('content 1');
        const size1 = 100;
        const date1 = new Date(2023, 1, 1);
        
        const file2 = 'test/file2.txt';
        const hash2 = createHash('content 2');
        const size2 = 200;
        const date2 = new Date(2023, 2, 1);
        
        hashCache.addHash(file1, { hash: hash1, length: size1, lastModified: date1 });
        hashCache.addHash(file2, { hash: hash2, length: size2, lastModified: date2 });
        
        // Save the cache
        await hashCache.save();
        
        // Create a new cache instance and load
        const newCache = new HashCache(mockStorage, cacheDir);
        const loaded = await newCache.load();
        
        expect(loaded).toBe(true);
        expect(newCache.getEntryCount()).toBe(2);
        
        // Check that hashes are retrieved correctly
        const retrieved1 = newCache.getHash(file1);
        expect(retrieved1).toBeDefined();
        expect(retrieved1!.hash.toString('hex')).toBe(hash1.toString('hex'));
        expect(retrieved1!.length).toBe(size1);
        expect(retrieved1!.lastModified.getTime()).toBe(date1.getTime());
        
        const retrieved2 = newCache.getHash(file2);
        expect(retrieved2).toBeDefined();
        expect(retrieved2!.hash.toString('hex')).toBe(hash2.toString('hex'));
        expect(retrieved2!.length).toBe(size2);
        expect(retrieved2!.lastModified.getTime()).toBe(date2.getTime());
    });
    
    test('should handle non-existent hashes', async () => {
        await hashCache.load();
        
        const result = hashCache.getHash('non-existent-file.txt');
        expect(result).toBeUndefined();
    });
    
    test('should remove hash', async () => {
        await hashCache.load();
        
        const filePath = 'test/file3.txt';
        const hash = createHash('content');
        const fileSize = 100;
        const lastModified = new Date();
        
        hashCache.addHash(filePath, { hash, length: fileSize, lastModified });
        expect(hashCache.getEntryCount()).toBe(1);
        
        // Remove the hash
        const removed = hashCache.removeHash(filePath);
        expect(removed).toBe(true);
        expect(hashCache.getEntryCount()).toBe(0);
        
        // Try to get the removed hash
        const result = hashCache.getHash(filePath);
        expect(result).toBeUndefined();
    });
    
    test('should return false when removing non-existent hash', async () => {
        await hashCache.load();
        
        const removed = hashCache.removeHash('non-existent-file.txt');
        expect(removed).toBe(false);
    });
    
    test('should properly handle paths with different slashes', async () => {
        await hashCache.load();
        
        const filePath = 'test\\file4.txt'; // Windows-style path
        const hash = createHash('content');
        const fileSize = 100;
        const lastModified = new Date();
        
        hashCache.addHash(filePath, { hash, length: fileSize, lastModified });
        
        // Should normalize paths internally
        const retrieved = hashCache.getHash('test/file4.txt'); // Unix-style path
        expect(retrieved).toBeDefined();
        expect(retrieved!.hash.toString('hex')).toBe(hash.toString('hex'));
    });
    
    test('should maintain sorted order when adding hashes', async () => {
        await hashCache.load();
        
        // Add hashes in non-alphabetical order
        const files = [
            'z/file.txt',
            'a/file.txt',
            'm/file.txt',
            'c/file.txt'
        ];
        
        for (const file of files) {
            const hash = createHash(`content of ${file}`);
            hashCache.addHash(file, { hash, length: 100, lastModified: new Date() });
        }
        
        // Save and reload to verify order
        await hashCache.save();
        
        const newCache = new HashCache(mockStorage, cacheDir);
        await newCache.load();
        
        // Verify all hashes can be retrieved
        for (const file of files) {
            const retrieved = newCache.getHash(file);
            expect(retrieved).toBeDefined();
            expect(retrieved!.hash.toString('hex')).toBe(createHash(`content of ${file}`).toString('hex'));
        }
    });
    
    test('should handle buffer resizing for large entries', async () => {
        await hashCache.load();
        
        // Add a large number of entries to force buffer resizing
        const largeEntryCount = 1000;
        
        for (let i = 0; i < largeEntryCount; i++) {
            const filePath = `file${i.toString().padStart(4, '0')}.txt`;
            const hash = createHash(`content ${i}`);
            hashCache.addHash(filePath, { hash, length: i, lastModified: new Date() });
        }
        
        expect(hashCache.getEntryCount()).toBe(largeEntryCount);
        
        // Verify a random entry
        const randomIndex = Math.floor(Math.random() * largeEntryCount);
        const filePath = `file${randomIndex.toString().padStart(4, '0')}.txt`;
        const retrieved = hashCache.getHash(filePath);
        
        expect(retrieved).toBeDefined();
        expect(retrieved!.hash.toString('hex')).toBe(createHash(`content ${randomIndex}`).toString('hex'));
        expect(retrieved!.length).toBe(randomIndex);
    });
    
    test('should correctly calculate entry size', async () => {
        await hashCache.load();
        
        // Add entries with different path lengths
        const shortPath = 'a.txt';
        const longPath = 'very/long/path/with/multiple/directories/and/a/long/filename.extension';
        
        hashCache.addHash(shortPath, { 
            hash: createHash('short'), 
            length: 100, 
            lastModified: new Date() 
        });
        
        hashCache.addHash(longPath, { 
            hash: createHash('long'), 
            length: 200, 
            lastModified: new Date() 
        });
        
        // Save and reload to verify
        await hashCache.save();
        
        const newCache = new HashCache(mockStorage, cacheDir);
        await newCache.load();
        
        // Verify both entries
        const retrievedShort = newCache.getHash(shortPath);
        expect(retrievedShort).toBeDefined();
        expect(retrievedShort!.hash.toString('hex')).toBe(createHash('short').toString('hex'));
        
        const retrievedLong = newCache.getHash(longPath);
        expect(retrievedLong).toBeDefined();
        expect(retrievedLong!.hash.toString('hex')).toBe(createHash('long').toString('hex'));
    });
    
    test('should validate hash length', async () => {
        await hashCache.load();
        
        const filePath = 'test/file.txt';
        const invalidHash = Buffer.from('too-short'); // Not 32 bytes
        
        expect(() => {
            hashCache.addHash(filePath, { 
                hash: invalidHash, 
                length: 100, 
                lastModified: new Date() 
            });
        }).toThrow(/Invalid hash length/);
    });
    
    test('should handle binary search edge cases', async () => {
        await hashCache.load();
        
        // Add entries to test binary search
        for (let i = 0; i < 10; i += 2) { // Add even numbers only
            const filePath = `file${i}.txt`;
            hashCache.addHash(filePath, { 
                hash: createHash(`content ${i}`), 
                length: i, 
                lastModified: new Date() 
            });
        }
        
        // Test getting a hash at the start of the range
        expect(hashCache.getHash('file0.txt')).toBeDefined();
        
        // Test getting a hash at the end of the range
        expect(hashCache.getHash('file8.txt')).toBeDefined();
        
        // Test getting a hash in the middle
        expect(hashCache.getHash('file4.txt')).toBeDefined();
        
        // Test with missing hashes (odd numbers)
        expect(hashCache.getHash('file1.txt')).toBeUndefined();
        expect(hashCache.getHash('file3.txt')).toBeUndefined();
        expect(hashCache.getHash('file5.txt')).toBeUndefined();
        
        // Test with a path that would be before the first entry
        expect(hashCache.getHash('aaa.txt')).toBeUndefined();
        
        // Test with a path that would be after the last entry
        expect(hashCache.getHash('zzz.txt')).toBeUndefined();
    });
});