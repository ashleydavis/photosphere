
//
// Generates a unique id.
// When NODE_ENV is set to "testing", generates deterministic UUIDs for predictable test results.
//
export function uuid():  string {
    if (process.env.NODE_ENV === "testing") {
        return generateDeterministicUuid();
    }
    return crypto.randomUUID();
}

//
// Counter for deterministic UUID generation in testing mode.
//
let testUuidCounter = 0;

//
// Generates deterministic UUIDs for testing that are well-distributed across shards.
// Uses a combination of hash functions to ensure good distribution while remaining predictable.
//
function generateDeterministicUuid(): string {
    testUuidCounter++;
    
    // Use multiple hash functions to create good distribution
    // Golden ratio multiplier for good distribution
    const phi = 0x9e3779b9;
    
    // Create multiple hash values from the counter
    let hash1 = testUuidCounter * phi;
    let hash2 = (testUuidCounter ^ 0xaaaaaaaa) * phi;
    let hash3 = (testUuidCounter ^ 0x55555555) * phi;
    
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