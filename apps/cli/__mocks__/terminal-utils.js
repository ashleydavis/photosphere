// Mock for terminal-utils
function clearProgressMessage() {
    // Do nothing in tests
}

function writeProgress(message) {
    // Do nothing in tests  
}

module.exports = {
    clearProgressMessage,
    writeProgress
};

module.exports.default = module.exports;