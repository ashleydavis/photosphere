// Mock for tools package
async function verifyTools() {
    return {
        allAvailable: true,
        missingTools: []
    };
}

module.exports = {
    verifyTools
};

module.exports.default = module.exports;