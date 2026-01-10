import * as crypto from 'crypto';
import { BufferSet } from '../lib/buffer-set';

describe('BufferSet', () => {
    let bufferSet: BufferSet;
    
    beforeEach(() => {
        bufferSet = new BufferSet();
    });
    
    test('should add and check existence of buffers', () => {
        const hash1 = crypto.createHash("sha256").update("test1").digest();
        const hash2 = crypto.createHash("sha256").update("test2").digest();
        
        bufferSet.add(hash1);
        bufferSet.add(hash2);
        
        expect(bufferSet.has(hash1)).toBe(true);
        expect(bufferSet.has(hash2)).toBe(true);
        expect(bufferSet.size).toBe(2);
    });
    
    test('should not add duplicate buffers', () => {
        const hash = crypto.createHash("sha256").update("test").digest();
        
        bufferSet.add(hash);
        bufferSet.add(hash);
        
        expect(bufferSet.size).toBe(1);
    });
    
    test('should delete buffers', () => {
        const hash = crypto.createHash("sha256").update("test").digest();
        
        bufferSet.add(hash);
        expect(bufferSet.has(hash)).toBe(true);
        
        const deleted = bufferSet.delete(hash);
        expect(deleted).toBe(true);
        expect(bufferSet.has(hash)).toBe(false);
        expect(bufferSet.size).toBe(0);
    });
    
    test('should return false when deleting non-existent buffer', () => {
        const hash = crypto.createHash("sha256").update("test").digest();
        const deleted = bufferSet.delete(hash);
        expect(deleted).toBe(false);
    });
    
    test('should handle buffer content equality (not reference)', () => {
        const content = "test";
        const hash1 = crypto.createHash("sha256").update(content).digest();
        const hash2 = crypto.createHash("sha256").update(content).digest();
        
        bufferSet.add(hash1);
        expect(bufferSet.has(hash2)).toBe(true); // Different reference, same content
    });
    
    test('should throw error for non-32-byte buffers', () => {
        const shortBuffer = Buffer.from("short");
        expect(() => bufferSet.add(shortBuffer)).toThrow('BufferSet expects 32-byte hashes');
    });
    
    test('should clear all buffers', () => {
        const hash1 = crypto.createHash("sha256").update("test1").digest();
        const hash2 = crypto.createHash("sha256").update("test2").digest();
        
        bufferSet.add(hash1);
        bufferSet.add(hash2);
        expect(bufferSet.size).toBe(2);
        
        bufferSet.clear();
        expect(bufferSet.size).toBe(0);
        expect(bufferSet.has(hash1)).toBe(false);
        expect(bufferSet.has(hash2)).toBe(false);
    });
    
    test('should iterate over values', () => {
        const hash1 = crypto.createHash("sha256").update("test1").digest();
        const hash2 = crypto.createHash("sha256").update("test2").digest();
        
        bufferSet.add(hash1);
        bufferSet.add(hash2);
        
        const values = Array.from(bufferSet.values());
        expect(values.length).toBe(2);
        expect(values.some(b => b.equals(hash1))).toBe(true);
        expect(values.some(b => b.equals(hash2))).toBe(true);
    });
    
    test('should support forEach', () => {
        const hash1 = crypto.createHash("sha256").update("test1").digest();
        const hash2 = crypto.createHash("sha256").update("test2").digest();
        
        bufferSet.add(hash1);
        bufferSet.add(hash2);
        
        const collected: Buffer[] = [];
        bufferSet.forEach((value) => {
            collected.push(value);
        });
        
        expect(collected.length).toBe(2);
        expect(collected.some(b => b.equals(hash1))).toBe(true);
        expect(collected.some(b => b.equals(hash2))).toBe(true);
    });
    
    test('should support iteration with for...of', () => {
        const hash1 = crypto.createHash("sha256").update("test1").digest();
        const hash2 = crypto.createHash("sha256").update("test2").digest();
        
        bufferSet.add(hash1);
        bufferSet.add(hash2);
        
        const collected: Buffer[] = [];
        for (const buffer of bufferSet) {
            collected.push(buffer);
        }
        
        expect(collected.length).toBe(2);
        expect(collected.some(b => b.equals(hash1))).toBe(true);
        expect(collected.some(b => b.equals(hash2))).toBe(true);
    });
    
    test('should handle hash collisions correctly', () => {
        // Create a mock BufferSet to test collision handling
        // We can't easily force a collision with the current hash function,
        // but we can verify the behavior by checking that different buffers
        // are stored correctly even if they theoretically could collide
        
        const buffers: Buffer[] = [];
        for (let i = 0; i < 100; i++) {
            const hash = crypto.createHash("sha256").update(`test${i}`).digest();
            buffers.push(hash);
            bufferSet.add(hash);
        }
        
        expect(bufferSet.size).toBe(100);
        
        // Verify all buffers are still accessible
        for (const buffer of buffers) {
            expect(bufferSet.has(buffer)).toBe(true);
        }
    });
    
    test('should handle entries iteration', () => {
        const hash1 = crypto.createHash("sha256").update("test1").digest();
        const hash2 = crypto.createHash("sha256").update("test2").digest();
        
        bufferSet.add(hash1);
        bufferSet.add(hash2);
        
        const entries = Array.from(bufferSet.entries());
        expect(entries.length).toBe(2);
        
        // Each entry should be [buffer, buffer] since it's a Set
        for (const [key, value] of entries) {
            expect(key.equals(value)).toBe(true);
        }
    });
    
    test('should find hash 0034217e5269895c55acc694c6423f3ddb695ecbbb68635d950cee57542a4d14 after adding it', () => {
        // This test demonstrates a bug in BufferSet.delete() where deleting a buffer from a collision bucket
        // causes issues finding other buffers in the same bucket
        // Target hash: 0034217e5269895c55acc694c6423f3ddb695ecbbb68635d950cee57542a4d14
        // Collision hash: 111111112222222233333333444444445555555566666666777777776094cf5e
        // Both have the same internal hash value (0x6094cf5e) and will be in the same bucket
        const hashBuffer = Buffer.from('0034217e5269895c55acc694c6423f3ddb695ecbbb68635d950cee57542a4d14', 'hex');
        const collisionBuffer = Buffer.from('111111112222222233333333444444445555555566666666777777776094cf5e', 'hex');
        
        // Verify it's 32 bytes (SHA-256)
        expect(hashBuffer.length).toBe(32);
        expect(collisionBuffer.length).toBe(32);
        
        // Add both buffers to the set (they will collide in the same bucket)
        bufferSet.add(hashBuffer);
        bufferSet.add(collisionBuffer);
        
        // Verify both were added
        expect(bufferSet.size).toBe(2);
        expect(bufferSet.has(hashBuffer)).toBe(true);
        expect(bufferSet.has(collisionBuffer)).toBe(true);
        
        // Delete the collision buffer first (simulating deleting a different node that collides)
        bufferSet.delete(collisionBuffer);
        
        // Verify the collision buffer is gone
        expect(bufferSet.has(collisionBuffer)).toBe(false);
        expect(bufferSet.size).toBe(1);
        
        // Create a new buffer with the same content as hashBuffer (different reference, simulating nodeA.hash)
        const hashBuffer2 = Buffer.from('0034217e5269895c55acc694c6423f3ddb695ecbbb68635d950cee57542a4d14', 'hex');
        
        // This should find it, but due to the bug in delete() it doesn't
        // The bug: After deleting the collision buffer, the target buffer becomes unfindable
        // even though it's still in the set (size is 1, and setB_debug would find it)
        expect(bufferSet.has(hashBuffer2)).toBe(true);
    });
});

