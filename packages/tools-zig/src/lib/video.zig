const std = @import("std");
const node_utils = @import("node-utils-zig");
const version_match = @import("version-match.zig");
const exec = node_utils.exec.exec;

//
// The result of Video.verifyFfprobe and Video.verifyFfmpeg
// (TypeScript: `{ available: boolean; version?: string; error?: string }`).
//
pub const VideoToolStatus = struct {
    // True when the tool can be run.
    available: bool,

    // The tool version, when available.
    version: ?[]const u8 = null,

    // Why the tool is not available.
    @"error": ?[]const u8 = null,
};

//
// Wraps ffprobe and ffmpeg. Only the tool verification is ported.
//
pub const Video = struct {
    // Not ported: constructor, configure, initializeCommands and the video processing methods
    // (not used by replicate or verify).

    //
    // Verify that ffprobe is available
    //
    pub fn verifyFfprobe(allocator: std.mem.Allocator, io: std.Io) VideoToolStatus {
        const result = exec(allocator, io, "ffprobe -version") catch {
            return .{
                .available = false,
                .@"error" = "ffprobe not found. Make sure ffmpeg is installed.",
            };
        };

        const versionMatch = version_match.matchAfter(result.stdout, "ffprobe version ", version_match.isNonWhitespaceCharacter);
        return .{
            .available = true,
            .version = versionMatch orelse "unknown",
        };
    }

    //
    // Verify that ffmpeg is available
    //
    pub fn verifyFfmpeg(allocator: std.mem.Allocator, io: std.Io) VideoToolStatus {
        const result = exec(allocator, io, "ffmpeg -version") catch {
            return .{
                .available = false,
                .@"error" = "ffmpeg not found. Make sure ffmpeg is installed.",
            };
        };

        const versionMatch = version_match.matchAfter(result.stdout, "ffmpeg version ", version_match.isNonWhitespaceCharacter);
        return .{
            .available = true,
            .version = versionMatch orelse "unknown",
        };
    }
};
