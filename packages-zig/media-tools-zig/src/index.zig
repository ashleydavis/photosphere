// ImageMagick, built into the program and run in its process.
pub const image_magick = @import("lib/image-magick.zig");
pub const ImageMagick = image_magick.ImageMagick;

// FFmpeg's ffmpeg and ffprobe, built into the program and run in its process.
pub const ffmpeg = @import("lib/ffmpeg.zig");
pub const Ffmpeg = ffmpeg.Ffmpeg;

// Running a tool built into the program from the code that uses it: the command checked and logged.
pub const tool_run = @import("lib/tool-run.zig");
pub const Tool = tool_run.Tool;
pub const ToolOutput = tool_run.ToolOutput;

// The start and stop of the libraries of the tools built into the program.
pub const media_tools = @import("lib/media-tools.zig");
pub const MediaTools = media_tools.MediaTools;
