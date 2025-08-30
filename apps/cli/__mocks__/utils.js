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
    generate() {
        return 'test-uuid';
    }
}

class TimestampProvider {
    now() {
        return new Date();
    }
}

class TestTimestampProvider {
    now() {
        return new Date('2023-01-01T00:00:00Z');
    }
}

const exports = {
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

module.exports = exports;
module.exports.default = exports;