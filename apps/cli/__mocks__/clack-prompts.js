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

async function multiline({ message }) {
    // Return a test PEM string in tests
    return 'test-pem';
}

// The animated spinner. A jest.fn so a test can assert whether it was reached at all: the CLI's own
// spinner() only creates one for an interactive run, because the animated one takes hold of the
// terminal (see apps/cli/src/lib/spinner.ts).
const spinner = jest.fn(() => ({
    start() {
        return;
    },
    stop() {
        return;
    },
    message() {
        return;
    },
    isCancelled: false,
}));

module.exports = {
    confirm,
    isCancel,
    select,
    outro,
    intro,
    note,
    text,
    multiline,
    spinner
};

module.exports.default = module.exports;