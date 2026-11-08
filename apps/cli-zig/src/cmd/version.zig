const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const node_utils = @import("node-utils-zig");
const merkle_tree = @import("merkle-tree-zig");
const pc = @import("../lib/picocolors.zig");
const config = @import("../lib/config.zig");
const getBuiltInToolVersions = @import("tools.zig").getBuiltInToolVersions;
const version = config.version;
const buildMetadata = config.buildMetadata;
const getCacheDir = node_utils.fs.getCacheDir;
const getConfigDir = node_utils.fs.getConfigDir;
const getProcessTmpDir = node_utils.fs.getProcessTmpDir;
const InProcessRunner = node_utils.in_process_tools.InProcessRunner;
const join = node_utils.path.join;
const CURRENT_DATABASE_VERSION = merkle_tree.merkle_tree.CURRENT_DATABASE_VERSION;

//
// Formats a message into the allocator.
//
fn text(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(allocator, fmt, args);
}

//
// Command that displays version information for psi and its dependencies.
// toolRunner runs the ImageMagick and FFmpeg built into the program, whose versions are shown.
//
pub fn versionCommand(allocator: std.mem.Allocator, io: std.Io, log: ILog, toolRunner: InProcessRunner) !void {

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

    // The versions of the tools built into the program
    const toolVersions = try getBuiltInToolVersions(allocator, io, log, toolRunner);

    log.info("");
    log.info(try pc.bold(allocator, "Dependencies:"));
    log.info(try text(allocator, "  {s}: {s}", .{ try pc.bold(allocator, "ImageMagick (magick)"), try pc.green(allocator, toolVersions.magick) }));
    log.info(try text(allocator, "  {s}: {s}", .{ try pc.bold(allocator, "ffmpeg"), try pc.green(allocator, toolVersions.ffmpeg) }));
    log.info(try text(allocator, "  {s}: {s}", .{ try pc.bold(allocator, "ffprobe"), try pc.green(allocator, toolVersions.ffprobe) }));

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
}
