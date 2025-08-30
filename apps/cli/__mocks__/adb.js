// Mock for adb package
const CURRENT_DATABASE_VERSION = 3;

function checkVersionCompatibility(merkleTree, allowOlderVersions) {
    return {
        isCompatible: true,
        currentVersion: CURRENT_DATABASE_VERSION,
        databaseVersion: CURRENT_DATABASE_VERSION
    };
}

async function loadTreeVersion(filePath, storage) {
    // Mock function that returns current database version
    return CURRENT_DATABASE_VERSION;
}

module.exports = {
    CURRENT_DATABASE_VERSION,
    checkVersionCompatibility,
    loadTreeVersion
};

module.exports.default = module.exports;