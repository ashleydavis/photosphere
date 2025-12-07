// Mock for mime package used in tests
// This mock provides comprehensive mime type detection for integration tests

function getType(path) {
    if (!path) {
        return null;
    }
    
    const lowerPath = path.toLowerCase();
    
    // Images
    if (lowerPath.endsWith('.jpg') || lowerPath.endsWith('.jpeg')) {
        return 'image/jpeg';
    }
    if (lowerPath.endsWith('.png')) {
        return 'image/png';
    }
    if (lowerPath.endsWith('.gif')) {
        return 'image/gif';
    }
    if (lowerPath.endsWith('.webp')) {
        return 'image/webp';
    }
    if (lowerPath.endsWith('.bmp')) {
        return 'image/bmp';
    }
    if (lowerPath.endsWith('.svg')) {
        return 'image/svg+xml';
    }
    if (lowerPath.endsWith('.psd')) {
        return 'image/vnd.adobe.photoshop';
    }
    if (lowerPath.endsWith('.fbs')) {
        return 'image/vnd.fastbidsheet';
    }
    
    // Videos
    if (lowerPath.endsWith('.mp4')) {
        return 'video/mp4';
    }
    if (lowerPath.endsWith('.mov')) {
        return 'video/quicktime';
    }
    if (lowerPath.endsWith('.avi')) {
        return 'video/x-msvideo';
    }
    if (lowerPath.endsWith('.webm')) {
        return 'video/webm';
    }
    
    // Archives
    if (lowerPath.endsWith('.zip')) {
        return 'application/zip';
    }
    
    // TypeScript files (detected as video/mp2t by mime)
    if (lowerPath.endsWith('.ts')) {
        return 'video/mp2t';
    }
    
    // Unknown types
    return null;
}

function getExtension(mimeType) {
    if (!mimeType) {
        return null;
    }
    
    const lowerMime = mimeType.toLowerCase();
    
    if (lowerMime === 'image/jpeg') {
        return 'jpg';
    }
    if (lowerMime === 'image/png') {
        return 'png';
    }
    if (lowerMime === 'image/gif') {
        return 'gif';
    }
    if (lowerMime === 'image/webp') {
        return 'webp';
    }
    if (lowerMime === 'image/bmp') {
        return 'bmp';
    }
    if (lowerMime === 'image/svg+xml') {
        return 'svg';
    }
    if (lowerMime === 'video/mp4') {
        return 'mp4';
    }
    if (lowerMime === 'video/quicktime') {
        return 'mov';
    }
    if (lowerMime === 'application/zip') {
        return 'zip';
    }
    
    return null;
}

const mime = {
    getType,
    getExtension
};

module.exports = mime;
module.exports.default = mime;

