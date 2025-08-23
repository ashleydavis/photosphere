// Mock for config module to avoid loading real configuration
async function configureIfNeeded() {
    // Do nothing in tests
    return;
}

function getS3Config() {
    // Return empty config in tests
    return {};
}

function getGoogleApiKey() {
    // Return null in tests
    return null;
}

module.exports = {
    configureIfNeeded,
    getS3Config,
    getGoogleApiKey
};

module.exports.default = module.exports;