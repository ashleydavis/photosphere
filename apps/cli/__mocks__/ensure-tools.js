// Mock for ensure-tools module to skip tool checking in tests
async function ensureMediaProcessingTools() {
    // Always return success in tests
    return;
}

module.exports = {
    ensureMediaProcessingTools
};

module.exports.default = module.exports;