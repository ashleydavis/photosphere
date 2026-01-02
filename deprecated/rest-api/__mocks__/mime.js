// Mock for mime package used in tests
function getType(path) {
    // Return a default mime type for tests
    if (path.endsWith('.jpg') || path.endsWith('.jpeg')) {
        return 'image/jpeg';
    }
    if (path.endsWith('.png')) {
        return 'image/png';
    }
    if (path.endsWith('.mp4')) {
        return 'video/mp4';
    }
    return 'application/octet-stream';
}

function getExtension(mimeType) {
    // Return a default extension for tests
    if (mimeType === 'image/jpeg') {
        return 'jpg';
    }
    if (mimeType === 'image/png') {
        return 'png';
    }
    if (mimeType === 'video/mp4') {
        return 'mp4';
    }
    return 'bin';
}

const mime = {
    getType,
    getExtension
};

module.exports = mime;
module.exports.default = mime;