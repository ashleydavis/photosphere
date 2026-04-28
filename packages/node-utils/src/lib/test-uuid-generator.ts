import fs from 'fs';
import path from 'path';
import { IUuidGenerator } from 'utils';

//
// Test UUID generator that creates deterministic UUIDs with good shard distribution.
// Uses a file-backed counter with an exclusive-create lock so concurrent processes
// each receive a unique counter value without collisions.
//
export class TestUuidGenerator implements IUuidGenerator {
    private counterFilePath: string;
    private lockFilePath: string;

    constructor() {
        const testTmpDir = process.env.TEST_TMP_DIR || './test/tmp';
        this.counterFilePath = path.join(testTmpDir, 'photosphere-test-uuid-counter');
        this.lockFilePath = this.counterFilePath + '.lock';
    }

    generate(): string {
        this.acquireLock();
        try {
            let counter = 0;
            if (fs.existsSync(this.counterFilePath)) {
                const data = fs.readFileSync(this.counterFilePath, 'utf8');
                counter = parseInt(data.trim(), 10) || 0;
            }
            counter++;
            fs.writeFileSync(this.counterFilePath, counter.toString(), 'utf8');
            return this.generateDeterministicUuid(counter);
        } finally {
            this.releaseLock();
        }
    }

    //
    // Acquires a spinlock via O_CREAT|O_EXCL so only one process increments the counter
    // at a time. Removes a stale lock after 5 seconds of waiting.
    //
    private acquireLock(): void {
        fs.mkdirSync(path.dirname(this.lockFilePath), { recursive: true });
        const maxWaitMs = 5000;
        const startTime = Date.now();
        while (true) {
            try {
                const fd = fs.openSync(this.lockFilePath, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY);
                fs.closeSync(fd);
                return;
            } catch {
                if (Date.now() - startTime > maxWaitMs) {
                    // Stale lock — remove and take ownership.
                    try { fs.unlinkSync(this.lockFilePath); } catch {}
                    const fd = fs.openSync(this.lockFilePath, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY);
                    fs.closeSync(fd);
                    return;
                }
                // Short busy-spin before retrying.
                const spinEnd = Date.now() + 5;
                while (Date.now() < spinEnd) {}
            }
        }
    }

    private releaseLock(): void {
        try { fs.unlinkSync(this.lockFilePath); } catch {}
    }

    reset(): void {
        try { fs.unlinkSync(this.counterFilePath); } catch {}
        try { fs.unlinkSync(this.lockFilePath); } catch {}
    }

    private generateDeterministicUuid(counter: number): string {
        // Use multiple hash functions to create good distribution
        // Golden ratio multiplier for good distribution
        const phi = 0x9e3779b9;
        
        // Create multiple hash values from the counter
        let hash1 = counter * phi;
        let hash2 = (counter ^ 0xaaaaaaaa) * phi;
        let hash3 = (counter ^ 0x55555555) * phi;
        
        // Apply additional mixing to improve distribution
        hash1 = ((hash1 ^ (hash1 >>> 16)) * 0x85ebca6b) >>> 0;
        hash2 = ((hash2 ^ (hash2 >>> 16)) * 0xc2b2ae35) >>> 0; 
        hash3 = ((hash3 ^ (hash3 >>> 16)) * 0x27d4eb2d) >>> 0;
        
        // Final mixing step
        hash1 = (hash1 ^ (hash1 >>> 13)) >>> 0;
        hash2 = (hash2 ^ (hash2 >>> 13)) >>> 0;
        hash3 = (hash3 ^ (hash3 >>> 13)) >>> 0;
        
        // Build UUID parts with good distribution
        const part1 = hash1.toString(16).padStart(8, '0');
        const part2 = (hash2 & 0xffff).toString(16).padStart(4, '0');
        const part3 = ((hash2 >>> 16) & 0x0fff | 0x4000).toString(16); // Version 4
        const part4 = ((hash3 & 0x3fff) | 0x8000).toString(16); // Variant bits
        const part5 = (hash3 >>> 16).toString(16).padStart(4, '0') + 
                      ((hash1 ^ hash2) >>> 0).toString(16).padStart(8, '0');
        
        return `${part1}-${part2}-${part3}-${part4}-${part5}`;
    }
}
