// Mock for clack prompts to avoid interactive prompts in tests
async function confirm({ message }) {
    // Always return true in tests
    return true;
}

function isCancel(value) {
    // Never cancel in tests
    return false;
}

async function select({ message, options }) {
    // Return first option in tests, or a default value if no options
    if (options && options.length > 0 && options[0].value !== undefined) {
        return options[0].value;
    }
    return 'existing'; // Default value for encryption key selection
}

function outro(message) {
    // Do nothing in tests
    return;
}

function intro(message) {
    // Do nothing in tests
    return;
}

function note(message, title) {
    // Do nothing in tests
    return;
}

async function text({ message, placeholder, defaultValue, validate }) {
    // Return default value or a test string
    return defaultValue || 'test-input';
}

module.exports = {
    confirm,
    isCancel,
    select,
    outro,
    intro,
    note,
    text
};

module.exports.default = module.exports;