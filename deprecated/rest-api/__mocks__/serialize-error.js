// Mock for serialize-error package used in tests
function serializeError(error) {
    if (!error) {
        return { message: 'Unknown error' };
    }
    
    if (error instanceof Error) {
        return {
            name: error.name,
            message: error.message,
            stack: error.stack
        };
    }
    
    // For non-Error objects, try to serialize them
    if (typeof error === 'string') {
        return { message: error };
    }
    
    if (typeof error === 'object') {
        return error;
    }
    
    return { message: String(error) };
}

module.exports = { serializeError };
module.exports.default = { serializeError };

