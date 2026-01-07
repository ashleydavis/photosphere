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

function deserializeError(serialized) {
    if (!serialized) {
        return new Error('Unknown error');
    }
    
    // If it's already an Error, return it
    if (serialized instanceof Error) {
        return serialized;
    }
    
    // Reconstruct Error from serialized object
    const error = new Error(serialized.message || 'Unknown error');
    if (serialized.name) {
        error.name = serialized.name;
    }
    if (serialized.stack) {
        error.stack = serialized.stack;
    }
    
    return error;
}

module.exports = { serializeError, deserializeError };
module.exports.default = { serializeError, deserializeError };

