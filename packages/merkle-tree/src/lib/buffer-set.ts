/**
 * A Set implementation that uses Buffer content (not reference) for membership testing.
 * Uses a numeric hash derived from all bytes of the buffer for fast lookups.
 * Handles collisions by storing full buffers and comparing on collision.
 * 
 * Optimized for SHA-256 hashes (32 bytes).
 */
export class BufferSet {
    private _map: Map<number, Buffer[]>;

    constructor() {
        this._map = new Map();
    }

    // Create a numeric hash by XORing all 32-bit chunks of the buffer
    // Optimized for SHA-256 (32 bytes) - loop unrolled for maximum performance
    private _hash(buffer: Buffer): number {
        if (buffer.length !== 32) {
            throw new Error(`BufferSet expects 32-byte hashes (SHA-256), got ${buffer.length} bytes`);
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

    add(buffer: Buffer): this {
        const hash = this._hash(buffer);
        const bucket = this._map.get(hash);
        
        if (!bucket) {
            this._map.set(hash, [buffer]);
        } else {
            // Check if buffer already exists in bucket
            const exists = bucket.some(b => b.equals(buffer));
            if (!exists) {
                bucket.push(buffer);
            }
        }
        return this;
    }

    has(buffer: Buffer): boolean {
        const hash = this._hash(buffer);
        const bucket = this._map.get(hash);
        
        if (!bucket) return false;
        
        return bucket.some(b => b.equals(buffer));
    }

    delete(buffer: Buffer): boolean {
        const hash = this._hash(buffer);
        const bucket = this._map.get(hash);
        
        if (!bucket) return false;
        
        const index = bucket.findIndex(b => b.equals(buffer));
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

    forEach(callback: (value: Buffer, key: Buffer, set: BufferSet) => void): void {
        for (const bucket of this._map.values()) {
            for (const buffer of bucket) {
                callback(buffer, buffer, this);
            }
        }
    }

    *values(): IterableIterator<Buffer> {
        for (const bucket of this._map.values()) {
            for (const buffer of bucket) {
                yield buffer;
            }
        }
    }

    *keys(): IterableIterator<Buffer> {
        return this.values();
    }

    *entries(): IterableIterator<[Buffer, Buffer]> {
        for (const bucket of this._map.values()) {
            for (const buffer of bucket) {
                yield [buffer, buffer];
            }
        }
    }

    [Symbol.iterator](): IterableIterator<Buffer> {
        return this.values();
    }
}

