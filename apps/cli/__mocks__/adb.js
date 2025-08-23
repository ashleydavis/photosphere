// Mock for adb package
const CURRENT_DATABASE_VERSION = 2;

function checkVersionCompatibility(merkleTree, allowOlderVersions) {
    return {
        isCompatible: true,
        currentVersion: CURRENT_DATABASE_VERSION,
        databaseVersion: CURRENT_DATABASE_VERSION
    };
}

module.exports = {
    CURRENT_DATABASE_VERSION,
    checkVersionCompatibility
};

module.exports.default = module.exports;