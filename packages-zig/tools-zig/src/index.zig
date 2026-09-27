// Export main classes
pub const image = @import("lib/image.zig");
pub const Image = image.Image;
pub const video = @import("lib/video.zig");
pub const Video = video.Video;

// Export unified file info function
pub const file_info = @import("lib/file-info.zig");
pub const getFileInfo = file_info.getFileInfo;

pub const version_match = @import("lib/version-match.zig");
pub const types = @import("lib/types.zig");

// Export tool management functions
pub const tool_verification = @import("lib/tool-verification.zig");
pub const verifyTools = tool_verification.verifyTools;
pub const ToolStatus = tool_verification.ToolStatus;
pub const ToolsStatus = tool_verification.ToolsStatus;
