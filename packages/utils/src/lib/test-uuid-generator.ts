import type { IUuidGenerator } from "./uuid-generator";

//
// Browser-safe test UUID generator that creates deterministic UUIDs with good shard
// distribution. Uses an in-memory counter so the class is safe to import into the
// renderer/Vite bundle (the file-backed TestUuidGenerator in node-utils cannot run
// in a browser context because it depends on fs/path). Each instance counts from
// zero independently.
//
export class TestUuidGenerator implements IUuidGenerator {
    // Monotonically increasing counter incremented on every generate() call.
    private counter: number = 0;

    generate(): string {
        this.counter++;
        return this.generateDeterministicUuid(this.counter);
    }

    reset(): void {
        this.counter = 0;
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
        const part1 = hash1.toString(16).padStart(8, "0");
        const part2 = (hash2 & 0xffff).toString(16).padStart(4, "0");
        const part3 = ((hash2 >>> 16) & 0x0fff | 0x4000).toString(16); // Version 4
        const part4 = ((hash3 & 0x3fff) | 0x8000).toString(16); // Variant bits
        const part5 = (hash3 >>> 16).toString(16).padStart(4, "0") +
                      ((hash1 ^ hash2) >>> 0).toString(16).padStart(8, "0");

        return `${part1}-${part2}-${part3}-${part4}-${part5}`;
    }
}
