// ImageMagick, built into the program and run in its process.
pub const image_magick = @import("lib/image-magick.zig");
pub const ImageMagick = image_magick.ImageMagick;

// FFmpeg's ffmpeg and ffprobe, built into the program and run in its process.
pub const ffmpeg = @import("lib/ffmpeg.zig");
pub const Ffmpeg = ffmpeg.Ffmpeg;

// The tools built into the program, as the runner the code that runs tools takes.
pub const media_tools = @import("lib/media-tools.zig");
pub const MediaTools = media_tools.MediaTools;
