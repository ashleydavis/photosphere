import fs from 'fs';
import path from 'path';
import { IUuidGenerator } from 'utils';

//
// Test UUID generator that creates deterministic UUIDs with good shard distribution
//
export class TestUuidGenerator implements IUuidGenerator {
    private counter: number = 0;
    private counterFilePath: string;
    private initialized: boolean = false;

    constructor() {
        // Store counter in test directory
        this.counterFilePath = path.join('./test/tmp', 'photosphere-test-uuid-counter');
    }

    generate(): string {
        this.initializeCounter();
        this.counter++;
        this.saveCounter();
        
        return this.generateDeterministicUuid(this.counter);
    }

    private initializeCounter(): void {
        if (this.initialized) {
            return;
        }
        
        if (fs.existsSync(this.counterFilePath)) {
            const fileStats = fs.statSync(this.counterFilePath);
            const counterData = fs.readFileSync(this.counterFilePath, 'utf8');
           
            const trimmedData = counterData.trim();
            this.counter = parseInt(trimmedData, 10) || 0;
            
        } else {
            this.counter = 0;
        }
        
        this.initialized = true;
    }

    private saveCounter(): void {
        // Ensure the directory exists before writing the file
        const dir = path.dirname(this.counterFilePath);
        if (!fs.existsSync(dir)) {
            fs.mkdirSync(dir, { recursive: true });
        }
        
        const counterValue = this.counter.toString();
        fs.writeFileSync(this.counterFilePath, counterValue, 'utf8');
    }

    reset(): void {
        this.counter = 0;
        this.initialized = false;
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