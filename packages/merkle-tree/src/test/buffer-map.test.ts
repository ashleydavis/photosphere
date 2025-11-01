import * as crypto from 'crypto';
import { BufferMap } from '../lib/buffer-map';

describe('BufferMap', () => {
    let bufferMap: BufferMap<string>;
    
    beforeEach(() => {
        bufferMap = new BufferMap<string>();
    });
    
    test('should set and get values', () => {
        const key1 = crypto.createHash("sha256").update("test1").digest();
        const key2 = crypto.createHash("sha256").update("test2").digest();
        
        bufferMap.set(key1, "value1");
        bufferMap.set(key2, "value2");
        
        expect(bufferMap.get(key1)).toBe("value1");
        expect(bufferMap.get(key2)).toBe("value2");
        expect(bufferMap.size).toBe(2);
    });
    
    test('should update existing values', () => {
        const key = crypto.createHash("sha256").update("test").digest();
        
        bufferMap.set(key, "value1");
        bufferMap.set(key, "value2");
        
        expect(bufferMap.get(key)).toBe("value2");
        expect(bufferMap.size).toBe(1);
    });
    
    test('should return undefined for non-existent keys', () => {
        const key = crypto.createHash("sha256").update("test").digest();
        expect(bufferMap.get(key)).toBeUndefined();
    });
    
    test('should check key existence with has', () => {
        const key = crypto.createHash("sha256").update("test").digest();
        
        expect(bufferMap.has(key)).toBe(false);
        
        bufferMap.set(key, "value");
        expect(bufferMap.has(key)).toBe(true);
    });
    
    test('should delete key-value pairs', () => {
        const key = crypto.createHash("sha256").update("test").digest();
        
        bufferMap.set(key, "value");
        expect(bufferMap.has(key)).toBe(true);
        
        const deleted = bufferMap.delete(key);
        expect(deleted).toBe(true);
        expect(bufferMap.has(key)).toBe(false);
        expect(bufferMap.get(key)).toBeUndefined();
        expect(bufferMap.size).toBe(0);
    });
    
    test('should return false when deleting non-existent key', () => {
        const key = crypto.createHash("sha256").update("test").digest();
        const deleted = bufferMap.delete(key);
        expect(deleted).toBe(false);
    });
    
    test('should handle buffer key content equality (not reference)', () => {
        const content = "test";
        const key1 = crypto.createHash("sha256").update(content).digest();
        const key2 = crypto.createHash("sha256").update(content).digest();
        
        bufferMap.set(key1, "value");
        expect(bufferMap.get(key2)).toBe("value"); // Different reference, same content
        expect(bufferMap.has(key2)).toBe(true);
    });
    
    test('should throw error for non-32-byte buffer keys', () => {
        const shortBuffer = Buffer.from("short");
        expect(() => bufferMap.set(shortBuffer, "value")).toThrow('BufferMap expects 32-byte hashes');
    });
    
    test('should clear all entries', () => {
        const key1 = crypto.createHash("sha256").update("test1").digest();
        const key2 = crypto.createHash("sha256").update("test2").digest();
        
        bufferMap.set(key1, "value1");
        bufferMap.set(key2, "value2");
        expect(bufferMap.size).toBe(2);
        
        bufferMap.clear();
        expect(bufferMap.size).toBe(0);
        expect(bufferMap.has(key1)).toBe(false);
        expect(bufferMap.has(key2)).toBe(false);
    });
    
    test('should iterate over values', () => {
        const key1 = crypto.createHash("sha256").update("test1").digest();
        const key2 = crypto.createHash("sha256").update("test2").digest();
        
        bufferMap.set(key1, "value1");
        bufferMap.set(key2, "value2");
        
        const values = Array.from(bufferMap.values());
        expect(values.length).toBe(2);
        expect(values).toContain("value1");
        expect(values).toContain("value2");
    });
    
    test('should iterate over keys', () => {
        const key1 = crypto.createHash("sha256").update("test1").digest();
        const key2 = crypto.createHash("sha256").update("test2").digest();
        
        bufferMap.set(key1, "value1");
        bufferMap.set(key2, "value2");
        
        const keys = Array.from(bufferMap.keys());
        expect(keys.length).toBe(2);
        expect(keys.some(k => k.equals(key1))).toBe(true);
        expect(keys.some(k => k.equals(key2))).toBe(true);
    });
    
    test('should support forEach', () => {
        const key1 = crypto.createHash("sha256").update("test1").digest();
        const key2 = crypto.createHash("sha256").update("test2").digest();
        
        bufferMap.set(key1, "value1");
        bufferMap.set(key2, "value2");
        
        const collected: Array<[Buffer, string]> = [];
        bufferMap.forEach((value, key) => {
            collected.push([key, value]);
        });
        
        expect(collected.length).toBe(2);
        expect(collected.some(([k, v]) => k.equals(key1) && v === "value1")).toBe(true);
        expect(collected.some(([k, v]) => k.equals(key2) && v === "value2")).toBe(true);
    });
    
    test('should support iteration with for...of', () => {
        const key1 = crypto.createHash("sha256").update("test1").digest();
        const key2 = crypto.createHash("sha256").update("test2").digest();
        
        bufferMap.set(key1, "value1");
        bufferMap.set(key2, "value2");
        
        const collected: Array<[Buffer, string]> = [];
        for (const entry of bufferMap) {
            collected.push(entry);
        }
        
        expect(collected.length).toBe(2);
        expect(collected.some(([k, v]) => k.equals(key1) && v === "value1")).toBe(true);
        expect(collected.some(([k, v]) => k.equals(key2) && v === "value2")).toBe(true);
    });
    
    test('should handle entries iteration', () => {
        const key1 = crypto.createHash("sha256").update("test1").digest();
        const key2 = crypto.createHash("sha256").update("test2").digest();
        
        bufferMap.set(key1, "value1");
        bufferMap.set(key2, "value2");
        
        const entries = Array.from(bufferMap.entries());
        expect(entries.length).toBe(2);
        expect(entries.some(([k, v]) => k.equals(key1) && v === "value1")).toBe(true);
        expect(entries.some(([k, v]) => k.equals(key2) && v === "value2")).toBe(true);
    });
    
    test('should handle hash collisions correctly', () => {
        // Test with many entries to ensure collision handling works
        const entries: Array<[Buffer, string]> = [];
        for (let i = 0; i < 100; i++) {
            const key = crypto.createHash("sha256").update(`test${i}`).digest();
            const value = `value${i}`;
            entries.push([key, value]);
            bufferMap.set(key, value);
        }
        
        expect(bufferMap.size).toBe(100);
        
        // Verify all entries are still accessible
        for (const [key, value] of entries) {
            expect(bufferMap.get(key)).toBe(value);
            expect(bufferMap.has(key)).toBe(true);
        }
    });
    
    test('should work with different value types', () => {
        const numberMap = new BufferMap<number>();
        const key = crypto.createHash("sha256").update("test").digest();
        
        numberMap.set(key, 42);
        expect(numberMap.get(key)).toBe(42);
    });
    
    test('should work with object values', () => {
        interface TestObject {
            name: string;
            count: number;
        }
        
        const objectMap = new BufferMap<TestObject>();
        const key = crypto.createHash("sha256").update("test").digest();
        const obj = { name: "test", count: 5 };
        
        objectMap.set(key, obj);
        expect(objectMap.get(key)).toBe(obj);
        expect(objectMap.get(key)?.name).toBe("test");
        expect(objectMap.get(key)?.count).toBe(5);
    });
    
    test('should return this from set method for chaining', () => {
        const key1 = crypto.createHash("sha256").update("test1").digest();
        const key2 = crypto.createHash("sha256").update("test2").digest();
        
        const result = bufferMap
            .set(key1, "value1")
            .set(key2, "value2");
        
        expect(result).toBe(bufferMap);
        expect(bufferMap.size).toBe(2);
    });
});

