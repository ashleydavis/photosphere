const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const version_match = @import("version-match.zig");
const exec = node_utils.exec.exec;

//
// The kind of ImageMagick installation found (TypeScript: 'modern' | 'legacy' | 'none').
//
pub const ImageMagickType = enum {
    // ImageMagick 7: the `magick` command.
    modern,

    // ImageMagick 6: the `convert` and `identify` commands.
    legacy,

    // ImageMagick was not found.
    none,
};

//
// The result of Image.verifyImageMagick
// (TypeScript: `{ available: boolean; version?: string; error?: string; type?: 'modern' | 'legacy' }`).
//
pub const ImageMagickStatus = struct {
    // True when ImageMagick can be run.
    available: bool,

    // The ImageMagick version, when available.
    version: ?[]const u8 = null,

    // Why ImageMagick is not available.
    @"error": ?[]const u8 = null,

    // The kind of installation, when available.
    @"type": ?ImageMagickType = null,
};

//
// Gets the version from `magick -version` / `convert -version` output
// (`stdout.match(/Version: ImageMagick ([\d.-]+)/)`), or 'unknown'.
//
fn imageMagickVersion(stdout: []const u8) []const u8 {
    return version_match.matchAfter(stdout, "Version: ImageMagick ", version_match.isVersionNumberCharacter) orelse "unknown";
}

//
// Wraps ImageMagick. Only the tool verification is ported.
//
pub const Image = struct {
    // The command used to convert images.
    var convertCommand: []const u8 = "magick";

    // The command used to identify images.
    var identifyCommand: []const u8 = "magick identify";

    // True once initializeCommands has run (or the commands were configured).
    var isInitialized: bool = false;

    // The kind of ImageMagick installation found.
    var imageMagickType: ImageMagickType = .none;

    // Not ported: constructor, configure, and the image processing methods (not used by replicate or verify).

    //
    // Initialize ImageMagick commands by checking system PATH
    //
    fn initializeCommands(allocator: std.mem.Allocator, io: std.Io) !void {
        if (isInitialized) {
            return;
        }

        // First try modern ImageMagick (magick command)
        if (exec(allocator, io, "magick -version")) |result| {
            // If we get here, modern magick command works
            convertCommand = "magick";
            identifyCommand = "magick identify";
            imageMagickType = .modern;
            isInitialized = true;

            // Get version info
            const version = imageMagickVersion(result.stdout);

            utils.log.log.verbose("Using modern ImageMagick: magick");
            utils.log.log.verbose(try std.fmt.allocPrint(allocator, "ImageMagick version: {s}", .{version}));
            return;
        }
        else |_| {}

        // Try legacy ImageMagick (convert/identify commands)
        const convertResult = exec(allocator, io, "convert -version") catch {
            // Neither modern nor legacy ImageMagick found
            imageMagickType = .none;
            isInitialized = true;
            return;
        };
        _ = exec(allocator, io, "identify -version") catch {
            // Neither modern nor legacy ImageMagick found
            imageMagickType = .none;
            isInitialized = true;
            return;
        };

        // If we get here, legacy commands work
        convertCommand = "convert";
        identifyCommand = "identify";
        imageMagickType = .legacy;
        isInitialized = true;

        // Get version info from convert command
        const version = imageMagickVersion(convertResult.stdout);

        utils.log.log.verbose("Using legacy ImageMagick: convert/identify");
        utils.log.log.verbose(try std.fmt.allocPrint(allocator, "ImageMagick version: {s}", .{version}));
    }

    //
    // Verify that ImageMagick is available
    //
    pub fn verifyImageMagick(allocator: std.mem.Allocator, io: std.Io) !ImageMagickStatus {
        // Initialize commands if not already done
        try initializeCommands(allocator, io);

        if (imageMagickType == .modern) {
            const result = exec(allocator, io, "magick -version") catch |err| {
                return .{
                    .available = false,
                    .@"error" = try std.fmt.allocPrint(allocator, "Modern ImageMagick 'magick' command failed: Error: {s}", .{utils.errors.errorMessage(err)}),
                };
            };
            return .{
                .available = true,
                .version = imageMagickVersion(result.stdout),
                .@"type" = .modern,
            };
        }
        else if (imageMagickType == .legacy) {
            const result = exec(allocator, io, "convert -version") catch |err| {
                return .{
                    .available = false,
                    .@"error" = try std.fmt.allocPrint(allocator, "Legacy ImageMagick 'convert' command failed: Error: {s}", .{utils.errors.errorMessage(err)}),
                };
            };
            return .{
                .available = true,
                .version = imageMagickVersion(result.stdout),
                .@"type" = .legacy,
            };
        }
        else {
            return .{
                .available = false,
                .@"error" = "ImageMagick not found. Please install ImageMagick and ensure either 'magick' or 'convert'/'identify' commands are available.",
            };
        }
    }

    // Not ported: getImageMagickType (not used by replicate or verify).

    //
    // Forgets the detected installation so the next verifyImageMagick detects it again
    // (no TypeScript counterpart: used by tests, which cannot reload the module).
    //
    pub fn resetInitialization() void {
        convertCommand = "magick";
        identifyCommand = "magick identify";
        isInitialized = false;
        imageMagickType = .none;
    }
};
