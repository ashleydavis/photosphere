const std = @import("std");
const MuteLog = @import("utils-zig").mute_log.MuteLog;
const MemoryLog = @import("utils-zig").memory_log.MemoryLog;
const node_api = @import("node-api-zig");
const node_utils = @import("node-utils-zig");
const media_tools = @import("media-tools-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const validateFile = node_api.validation.validateFile;
const MediaTools = media_tools.MediaTools;
const InProcessRunner = node_utils.in_process_tools.InProcessRunner;

//
// These cover what validateFile decides.
//

test "a zero-byte file is not valid" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);

    // The validation logs the failure; a passing test must write nothing to stderr, so the log is muted.

    try std.testing.expectEqual(false, try validateFile(arena.allocator(), io, log, runner, "../test/test.png", "image/png", .{
        .length = 0,
        .lastModified = 0,
    }));
}

test "an image the media tools can measure is valid" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);

    try std.testing.expectEqual(true, try validateFile(arena.allocator(), io, log, runner, "../test/test.png", "image/png", .{
        .length = 100,
        .lastModified = 0,
    }));
}

test "a HEIC the bundled media tools can measure is valid" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    // ImageMagick has no HEIC support, and a machine's own ffprobe may be too old to read a HEIC's tile grid, so the bundled tools
    // are used, as the app does.
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();

    try std.testing.expectEqual(true, try validateFile(arena.allocator(), io, log, mediaTools.runner(), "../test/heic/tiled.heic", "image/heic", .{
        .length = 38956,
        .lastModified = 0,
    }));
}

test "an image the media tools cannot read is not valid" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    const dir = try temp_dirs.makeTempDir(allocator, io, "validation");
    defer temp_dirs.removeTempDir(io, dir);
    const filePath = try std.fs.path.join(allocator, &.{ dir, "broken.png" });
    try test_files.writeFile(io, filePath, "not a png");

    // The validation logs the failure; a passing test must write nothing to stderr, so the log is muted.

    try std.testing.expectEqual(false, try validateFile(allocator, io, log, runner, filePath, "image/png", .{
        .length = 9,
        .lastModified = 0,
    }));
}

test "a video the media tools can measure is valid" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);

    try std.testing.expectEqual(true, try validateFile(arena.allocator(), io, log, runner, "../test/multiple-files/test.mp4", "video/mp4", .{
        .length = 100,
        .lastModified = 0,
    }));
}

test "a Photoshop file is let through without being checked" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);

    try std.testing.expectEqual(true, try validateFile(arena.allocator(), io, log, runner, "no-such-file.psd", "image/vnd.adobe.photoshop", .{
        .length = 10,
        .lastModified = 0,
    }));
}

test "a file that is neither an image nor a video is valid" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);

    try std.testing.expectEqual(true, try validateFile(arena.allocator(), io, log, runner, "no-such-file.bin", "application/octet-stream", .{
        .length = 10,
        .lastModified = 0,
    }));
}

//
// Runs validateFile with a memory log, and returns whether the file was valid along with what was logged.
//
const IValidationOutcome = struct {
    // Whether validateFile let the file through.
    valid: bool,

    // What it logged to stderr.
    logged: []const u8,
};

//
// Validates the file with a memory log of its own, keeping what it logged to stderr.
//
fn validateCapturing(allocator: std.mem.Allocator, io: std.Io, runner: InProcessRunner, filePath: []const u8, contentType: []const u8) !IValidationOutcome {
    const memory = try MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    const valid = try validateFile(allocator, io, memory.log, runner, filePath, contentType, .{
        .length = 100,
        .lastModified = 0,
    });
    return .{
        .valid = valid,
        .logged = try allocator.dupe(u8, memory.stderr()),
    };
}

test "a content type that only starts with image or video gets no file info and is not valid" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);

    // getFileInfo only knows "image/" and "video/" types.
    const image = try validateCapturing(allocator, io, runner, "../test/test.png", "imagery");
    try std.testing.expectEqual(false, image.valid);
    try std.testing.expect(std.mem.indexOf(u8, image.logged, "Invalid image ../test/test.png - failed to get file info") != null);

    const video = try validateCapturing(allocator, io, runner, "../test/multiple-files/test.mp4", "videotape");
    try std.testing.expectEqual(false, video.valid);
    try std.testing.expect(std.mem.indexOf(u8, video.logged, "Invalid video ../test/multiple-files/test.mp4 - failed to get file info") != null);
}

test "a video the media tools cannot read is not valid" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);

    const dir = try temp_dirs.makeTempDir(allocator, io, "validation-video");
    defer temp_dirs.removeTempDir(io, dir);
    const filePath = try std.fs.path.join(allocator, &.{ dir, "broken.mp4" });
    try test_files.writeFile(io, filePath, "not a video");

    const outcome = try validateCapturing(allocator, io, runner, filePath, "video/mp4");

    try std.testing.expectEqual(false, outcome.valid);
    try std.testing.expect(std.mem.indexOf(u8, outcome.logged, try std.fmt.allocPrint(allocator, "Invalid video {s} - analysis failed", .{filePath})) != null);
}
