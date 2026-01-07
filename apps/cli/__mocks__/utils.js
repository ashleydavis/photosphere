// Mock for utils package used in tests
let mockLog = {
    info: jest.fn(),
    verbose: jest.fn(),
    error: jest.fn(),
    exception: jest.fn(),
    warn: jest.fn(),
    debug: jest.fn(),
    tool: jest.fn(),
    verboseEnabled: false
};

function setLog(newLog) {
    mockLog = newLog;
}

function sleep(ms) {
    return Promise.resolve();
}

class RandomUuidGenerator {
    generate() {
        return 'test-uuid-' + Math.random().toString(36).substr(2, 9);
    }
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

class TimestampProvider {
    now() {
        return Date.now();
    }
    
    dateNow() {
        return new Date();
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

module.exports = {
    log: mockLog,
    setLog,
    sleep,
    RandomUuidGenerator,
    TestUuidGenerator,
    TimestampProvider,
    TestTimestampProvider,
    retry: jest.fn().mockImplementation((fn) => fn()),
    reverseGeocode: jest.fn().mockResolvedValue(null),
    WrappedError: class WrappedError extends Error { },
    uuid: jest.fn().mockReturnValue('test-uuid')
};

module.exports.default = module.exports;