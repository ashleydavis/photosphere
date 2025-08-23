// Mock for log module to avoid setLog import issues
async function configureLog(options) {
    // Do nothing in tests
    return;
}

module.exports = {
    configureLog
};

module.exports.default = module.exports;