// Mock for node-utils package used in tests
async function exit(code) {
    // Don't actually exit in tests, just return
    return;
}

class TestUuidGenerator {
    constructor() {
        this.counter = 0;
    }
    
    generate() {
        this.counter++;
        return `test-uuid-${this.counter}`;
    }
}

class TestTimestampProvider {
    constructor() {
        this.counter = 0;
    }
    
    now() {
        const baseTimestamp = new Date('2023-01-01T00:00:00Z').getTime();
        return baseTimestamp + this.counter++;
    }
    
    dateNow() {
        return new Date(this.now());
    }
    
    reset() {
        this.counter = 0;
    }
}

function registerTerminationCallback(fn) {
    // Do nothing in tests
    return;
}

module.exports = {
    exit,
    TestUuidGenerator,
    TestTimestampProvider,
    registerTerminationCallback
};