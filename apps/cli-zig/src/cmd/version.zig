const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const tools = @import("tools-zig");
const merkle_tree = @import("merkle-tree-zig");
const pc = @import("../lib/picocolors.zig");
const config = @import("../lib/config.zig");
const log = &utils.log.log;
const verifyTools = tools.verifyTools;
const Image = tools.Image;
const version = config.version;
const buildMetadata = config.buildMetadata;
const getCacheDir = node_utils.fs.getCacheDir;
const getConfigDir = node_utils.fs.getConfigDir;
const getProcessTmpDir = node_utils.fs.getProcessTmpDir;
const join = node_utils.path.join;
const CURRENT_DATABASE_VERSION = merkle_tree.merkle_tree.CURRENT_DATABASE_VERSION;

//
// Formats a message into the allocator (TypeScript: a template literal).
//
fn text(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(allocator, fmt, args);
}

//
// Command that displays version information for psi and its dependencies.
//
pub fn versionCommand(allocator: std.mem.Allocator, io: std.Io) !void {

    log.info("");
    log.info(try pc.bold(allocator, "📋 Version Information\n"));

    // Show psi version
    log.info(try text(allocator, "{s}: {s}", .{ try pc.bold(allocator, "Photosphere"), try pc.green(allocator, version) }));

    // Show database version
    log.info(try text(allocator, "{s}: {s}", .{ try pc.bold(allocator, "Database version"), try pc.green(allocator, try text(allocator, "{d}", .{CURRENT_DATABASE_VERSION})) }));

    // Show build information if available
    if (!std.mem.eql(u8, buildMetadata.commitHash, "dev")) {
        log.info(try text(allocator, "{s}: {s}", .{ try pc.bold(allocator, "Commit"), try pc.cyan(allocator, buildMetadata.commitHash[0..@min(8, buildMetadata.commitHash.len)]) }));
        if (!std.mem.eql(u8, buildMetadata.buildDate, "development")) {
            log.info(try text(allocator, "{s}: {s}", .{ try pc.bold(allocator, "Built"), try pc.dim(allocator, buildMetadata.buildDate) }));
        }
        if (buildMetadata.isNightly) {
            log.info(try text(allocator, "{s}: {s}", .{ try pc.bold(allocator, "Type"), try pc.yellow(allocator, "Nightly Build") }));
        }
    }

    // Get tool versions
    const toolsStatus = try verifyTools(allocator, io);

    // Get ImageMagick type to display the correct name
    // Initialize ImageMagick first to ensure we have the correct type
    _ = try Image.verifyImageMagick(allocator, io);
    const imageMagickType = Image.getImageMagickType();
    var imageMagickName: []const u8 = "ImageMagick";

    if (imageMagickType == .legacy) {
        imageMagickName = "ImageMagick (convert/identify)";
    }
    else if (imageMagickType == .modern) {
        imageMagickName = "ImageMagick (magick)";
    }

    // Display dependency versions
    log.info("");
    log.info(try pc.bold(allocator, "Dependencies:"));

    // ImageMagick
    if (toolsStatus.magick.available and toolsStatus.magick.version != null) {
        log.info(try text(allocator, "  {s}: {s}", .{ try pc.bold(allocator, imageMagickName), try pc.green(allocator, toolsStatus.magick.version.?) }));
    }
    else {
        log.info(try text(allocator, "  {s}: {s}", .{ try pc.bold(allocator, imageMagickName), try pc.red(allocator, "Not found") }));
    }

    // FFmpeg
    if (toolsStatus.ffmpeg.available and toolsStatus.ffmpeg.version != null) {
        log.info(try text(allocator, "  {s}: {s}", .{ try pc.bold(allocator, "ffmpeg"), try pc.green(allocator, toolsStatus.ffmpeg.version.?) }));
    }
    else {
        log.info(try text(allocator, "  {s}: {s}", .{ try pc.bold(allocator, "ffmpeg"), try pc.red(allocator, "Not found") }));
    }

    // FFprobe
    if (toolsStatus.ffprobe.available and toolsStatus.ffprobe.version != null) {
        log.info(try text(allocator, "  {s}: {s}", .{ try pc.bold(allocator, "ffprobe"), try pc.green(allocator, toolsStatus.ffprobe.version.?) }));
    }
    else {
        log.info(try text(allocator, "  {s}: {s}", .{ try pc.bold(allocator, "ffprobe"), try pc.red(allocator, "Not found") }));
    }

    log.info("");

    log.info(try pc.bold(allocator, "Directories:"));
    const configDir = try getConfigDir(allocator);
    log.info(try text(allocator, "  {s}: {s}", .{ try pc.bold(allocator, "Config"), try pc.cyan(allocator, configDir) }));
    log.info(try text(allocator, "  {s}: {s}", .{ try pc.bold(allocator, "Temp"), try pc.cyan(allocator, try join(allocator, &.{ try getProcessTmpDir(allocator, io), "photosphere" })) }));
    log.info(try text(allocator, "  {s}: {s}", .{ try pc.bold(allocator, "Log files"), try pc.cyan(allocator, try join(allocator, &.{ try getProcessTmpDir(allocator, io), "photosphere", "logs" })) }));
    // Where this machine keeps what it has worked out about each database, the hash caches among
    // them. A directory per database rather than one file, and this command has no database in hand
    // to name a single one, so it names the root they all sit under.
    log.info(try text(allocator, "  {s}: {s}", .{ try pc.bold(allocator, "Cache"), try pc.cyan(allocator, try getCacheDir(allocator)) }));
    log.info("");

    // Show overall status
    if (toolsStatus.allAvailable) {
        log.info(try pc.green(allocator, "✅ All dependencies are available"));
    }
    else {
        log.info(try pc.yellow(allocator, try text(allocator, "⚠️  Some dependencies are missing: {s}", .{try std.mem.join(allocator, ", ", toolsStatus.missingTools)})));
        log.info(try pc.dim(allocator, "Run \"psi tools\" for installation instructions"));
    }
}
