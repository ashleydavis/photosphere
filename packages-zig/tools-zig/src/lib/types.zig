const std = @import("std");
const serialization_zig = @import("serialization-zig");
const BsonValue = serialization_zig.bson.BsonValue;

//
// The width and height of an image or video.
//
pub const Dimensions = struct {
    // The width, in pixels.
    width: f64,

    // The height, in pixels.
    height: f64,
};

//
// What an image or video tool reports about a file.
//
pub const AssetInfo = struct {
    // File information
    filePath: []const u8,

    // Visual properties
    dimensions: Dimensions,

    // Optional properties (may be null for images or videos)
    duration: ?f64 = null, // in seconds (null for images)
    fps: ?f64 = null, // frames per second (null for images)
    bitrate: ?f64 = null, // in bits/sec (mainly for videos)
    hasAudio: ?bool = null, // for videos

    // Common metadata: when the file was created, as a JavaScript time value (NaN for an Invalid Date).
    createdAt: ?f64 = null,

    // Raw metadata (EXIF for images, format tags for videos), a JavaScript object.
    metadata: ?BsonValue = null,
};

//
// Options for resizing an image.
//
pub const ResizeOptions = struct {
    // The width to resize to.
    width: f64,

    // The height to resize to.
    height: f64,

    // The quality of the output (0 to 100).
    quality: ?f64,

    // The format of the output ('jpeg' | 'jpg' | 'png' | 'webp' | 'gif' | 'bmp' | 'tiff').
    format: ?[]const u8,

    // The extension of the output file.
    ext: []const u8,

    // Keep the aspect ratio (TypeScript default: true).
    maintainAspectRatio: ?bool = null,
};

// Not ported: ImageMagickConfig, VideoConfig (Image.configure and Video.configure are not ported).
