// Mock for wrap-ansi module used in tests
function wrapAnsi(text, columns, options) {
    // Simple mock that just returns the text unchanged
    return text;
}

module.exports = wrapAnsi;
module.exports.default = wrapAnsi;