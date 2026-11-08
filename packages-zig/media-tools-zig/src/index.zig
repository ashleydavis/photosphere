// ImageMagick, built into the program and called through its C library: typed functions that read, resize, turn and write images.
pub const image_magick = @import("lib/image-magick.zig");

// FFmpeg, built into the program and called through its libraries: typed functions that probe videos, take a frame of one and decode
// HEIC pictures.
pub const ffmpeg = @import("lib/ffmpeg.zig");
