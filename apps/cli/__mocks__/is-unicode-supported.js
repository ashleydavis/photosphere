// Mock for is-unicode-supported module used in tests
function isUnicodeSupported() {
    // Simple mock that returns false (no unicode support)
    return false;
}

module.exports = isUnicodeSupported;
module.exports.default = isUnicodeSupported;