// Mock for node-utils package used in tests
async function exit(code) {
    // Don't actually exit in tests, just return
    return;
}

class TestUuidGenerator {
    generate() {
        return 'test-uuid';
    }
}

class TestTimestampProvider {
    now() {
        return new Date('2023-01-01T00:00:00Z');
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