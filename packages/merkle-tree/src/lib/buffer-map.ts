/**
 * A Map implementation that uses Buffers as keys.
 * Optimized for SHA-256 hashes (32 bytes).
 * 
 * Similar to how Map relates to Set in JavaScript,
 * BufferMap relates to BufferSet - storing key-value pairs
 * where keys are Buffers.
 */

export class BufferMap<V> {
    private _map: Map<number, Array<[Buffer, V]>>;

    constructor() {
        this._map = new Map();
    }

    // Create a numeric hash by XORing all 32-bit chunks of the buffer
    // Optimized for SHA-256 (32 bytes) - loop unrolled for maximum performance
    private _hash(buffer: Buffer): number {
        if (buffer.length !== 32) {
            throw new Error(`BufferMap expects 32-byte hashes (SHA-256), got ${buffer.length} bytes`);
        }
        
        // For SHA-256 hashes (32 bytes), XOR all 8 chunks
        return (
            buffer.readUInt32BE(0) ^
            buffer.readUInt32BE(4) ^
            buffer.readUInt32BE(8) ^
            buffer.readUInt32BE(12) ^
            buffer.readUInt32BE(16) ^
            buffer.readUInt32BE(20) ^
            buffer.readUInt32BE(24) ^
            buffer.readUInt32BE(28)
        ) >>> 0; // Ensure unsigned 32-bit integer
    }

    set(key: Buffer, value: V): this {
        const hash = this._hash(key);
        const bucket = this._map.get(hash);
        
        if (!bucket) {
            this._map.set(hash, [[key, value]]);
        } else {
            // Check if key already exists in bucket
            const index = bucket.findIndex(([k]) => k.equals(key));
            if (index >= 0) {
                // Update existing value
                bucket[index][1] = value;
            } else {
                // Add new key-value pair
                bucket.push([key, value]);
            }
        }
        return this;
    }

    get(key: Buffer): V | undefined {
        const hash = this._hash(key);
        const bucket = this._map.get(hash);
        
        if (!bucket) return undefined;
        
        const entry = bucket.find(([k]) => k.equals(key));
        return entry ? entry[1] : undefined;
    }

    has(key: Buffer): boolean {
        const hash = this._hash(key);
        const bucket = this._map.get(hash);
        
        if (!bucket) return false;
        
        return bucket.some(([k]) => k.equals(key));
    }

    delete(key: Buffer): boolean {
        const hash = this._hash(key);
        const bucket = this._map.get(hash);
        
        if (!bucket) return false;
        
        const index = bucket.findIndex(([k]) => k.equals(key));
        if (index < 0) return false;
        
        bucket.splice(index, 1);
        
        // Remove bucket if empty
        if (bucket.length === 0) {
            this._map.delete(hash);
        }
        
        return true;
    }

    clear(): void {
        this._map.clear();
    }

    get size(): number {
        let count = 0;
        for (const bucket of this._map.values()) {
            count += bucket.length;
        }
        return count;
    }

    forEach(callback: (value: V, key: Buffer, map: BufferMap<V>) => void): void {
        for (const bucket of this._map.values()) {
            for (const [key, value] of bucket) {
                callback(value, key, this);
            }
        }
    }

    *values(): IterableIterator<V> {
        for (const bucket of this._map.values()) {
            for (const [, value] of bucket) {
                yield value;
            }
        }
    }

    *keys(): IterableIterator<Buffer> {
        for (const bucket of this._map.values()) {
            for (const [key] of bucket) {
                yield key;
            }
        }
    }

    *entries(): IterableIterator<[Buffer, V]> {
        for (const bucket of this._map.values()) {
            for (const entry of bucket) {
                yield entry;
            }
        }
    }

    [Symbol.iterator](): IterableIterator<[Buffer, V]> {
        return this.entries();
    }
}

