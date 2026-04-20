// Mock for serialize-error package - avoids loading ESM package in Jest
function serializeError(error) {
    if (!error) {
        return { message: "Unknown error" };
    }
    if (error instanceof Error) {
        return { name: error.name, message: error.message, stack: error.stack };
    }
    if (typeof error === "string") {
        return { message: error };
    }
    if (typeof error === "object") {
        return error;
    }
    return { message: String(error) };
}

module.exports = { serializeError };
