const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const console_capture = @import("console-capture.zig");
const mock_log = @import("mock-log.zig");
const test_environment = @import("test-environment.zig");
const getVideoDetails = node_api.video.getVideoDetails;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;

//
// (Zig: there are no TypeScript tests of video.ts; these cover what getVideoDetails produces for the checked in
// test video.)
//

test "gets the resolution, duration and derived images of a video" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    const tempDir = try temp_dirs.makeTempDir(allocator, io, "video-details");
    defer temp_dirs.removeTempDir(io, tempDir);
    var generator = try TestUuidGenerator.init(allocator);

    const details = try getVideoDetails(allocator, io, "../test/multiple-files/test.mp4", tempDir, "video/mp4", generator.uuidGenerator(), "test.mp4");

    try std.testing.expect(details.resolution.width > 0);
    try std.testing.expect(details.resolution.height > 0);
    try std.testing.expect(details.duration.? > 0);
    try std.testing.expectEqualStrings("image/jpeg", details.thumbnailContentType);
    try std.testing.expect(details.displayPath == null);
    try std.testing.expect(test_files.fileExists(io, details.thumbnailPath));
    try std.testing.expect(test_files.fileExists(io, details.microPath));
}

test "reads the date of a video from the JSON file beside it when the video has none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    const tempDir = try temp_dirs.makeTempDir(allocator, io, "video-json-date");
    defer temp_dirs.removeTempDir(io, tempDir);
    var generator = try TestUuidGenerator.init(allocator);
    const videoPath = try std.fmt.allocPrint(allocator, "{s}/video.mp4", .{tempDir});
    try test_files.writeFile(io, videoPath, try test_files.readFile(allocator, io, "../test/multiple-files/test.mp4"));
    try test_files.writeFile(io, try std.fmt.allocPrint(allocator, "{s}.json", .{videoPath}), "{\"photoTakenTime\":{\"timestamp\":\"1700000000\"}}");

    const details = try getVideoDetails(allocator, io, videoPath, tempDir, "video/mp4", generator.uuidGenerator(), "video.mp4");

    // The test video carries no date of its own, so the JSON file's is used.
    try std.testing.expectEqualStrings("2023-11-14T22:13:20.000Z", details.photoDate.?);
}

//
// Gets the details of a copy of the test video with the given JSON file beside it.
//
fn detailsWithJson(allocator: std.mem.Allocator, name: []const u8, json: []const u8) !node_api.media_file_database.IAssetDetails {
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    const tempDir = try temp_dirs.makeTempDir(allocator, io, name);
    var generator = try TestUuidGenerator.init(allocator);
    const videoPath = try std.fmt.allocPrint(allocator, "{s}/video.mp4", .{tempDir});
    try test_files.writeFile(io, videoPath, try test_files.readFile(allocator, io, "../test/multiple-files/test.mp4"));
    try test_files.writeFile(io, try std.fmt.allocPrint(allocator, "{s}.json", .{videoPath}), json);
    const details = getVideoDetails(allocator, io, videoPath, tempDir, "video/mp4", generator.uuidGenerator(), "video.mp4");
    temp_dirs.removeTempDir(io, tempDir);
    return details;
}

test "a JSON timestamp is read as JavaScript's parseInt reads it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // parseInt(["1700000000"]) reads String(["1700000000"]), which is "1700000000".
    const fromArray = try detailsWithJson(allocator, "video-json-array", "{\"photoTakenTime\":{\"timestamp\":[\"1700000000\"]}}");
    try std.testing.expectEqualStrings("2023-11-14T22:13:20.000Z", fromArray.photoDate.?);

    // parseInt("0x10") is 16.
    const fromHex = try detailsWithJson(allocator, "video-json-hex", "{\"photoTakenTime\":{\"timestamp\":\"0x10\"}}");
    try std.testing.expectEqualStrings("1970-01-01T00:00:16.000Z", fromHex.photoDate.?);
}

test "a JSON timestamp that is not a number leaves the video undated rather than failing it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The code under test logs the failures below; a passing test must write nothing to stderr, so the log is muted.
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();

    // parseInt({}) is NaN, and dayjs.unix(NaN).toISOString() throws, which is caught and logged.
    const details = try detailsWithJson(allocator, "video-json-object", "{\"photoTakenTime\":{\"timestamp\":{\"seconds\":1}}}");
    try std.testing.expect(details.photoDate == null);

    // A number of seconds too large for a Date is an Invalid Date too.
    const tooLate = try detailsWithJson(allocator, "video-json-too-late", "{\"photoTakenTime\":{\"timestamp\":\"99999999999999999999999\"}}");
    try std.testing.expect(tooLate.photoDate == null);
}

//
// A JSON file beside a video, and the photo date getVideoDetails takes from it.
//
const IJsonDateCase = struct {
    // The contents of the JSON file.
    json: []const u8,

    // The photo date, or null when there is none.
    photoDate: ?[]const u8,

    // What is logged about it, or null when nothing is expected.
    logged: ?[]const u8,
};

//
// Writes a verbose message to stdout, where the test captures it (the console log's own verbose writes nothing).
//
fn verboseToStdout(ptr: *anyopaque, message: []const u8) void {
    _ = ptr;
    utils.console.log(message);
}

test "reads what it can of the JSON file beside a video, as dayjs.unix(parseInt(timestamp)) does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    const tempDir = try temp_dirs.makeTempDir(allocator, io, "video-json-cases");
    defer temp_dirs.removeTempDir(io, tempDir);
    var generator = try TestUuidGenerator.init(allocator);

    // A QuickTime file keeps a location tag as written, and has no date of its own. The first place the location
    // matches /([+-]\d+\.\d+)([+-]\d+\.\d+)/ is "+1.5-2.5".
    const videoPath = try std.fmt.allocPrint(allocator, "{s}/video.mov", .{tempDir});
    const made = try std.process.run(allocator, io, .{ .argv = &.{ "ffmpeg", "-v", "quiet", "-f", "lavfi", "-i", "color=c=red:s=32x16:r=10:d=1", "-metadata", "location=+5 +5. -1.5x +1.5-2.5/", "-pix_fmt", "yuv420p", "-y", videoPath } });
    try std.testing.expect(made.term == .exited and made.term.exited == 0);
    const jsonPath = try std.fmt.allocPrint(allocator, "{s}.json", .{videoPath});

    const cases = [_]IJsonDateCase{
        .{ .json = "{\"photoTakenTime\":{\"timestamp\":1700000000.7}}", .photoDate = "2023-11-14T22:13:20.000Z", .logged = "Parsed date 2023-11-14T22:13:20.000Z from timestamp 1700000000 in JSON file " },
        .{ .json = "{\"photoTakenTime\":{\"timestamp\":[\"1700000000\",5]}}", .photoDate = "2023-11-14T22:13:20.000Z", .logged = null },
        .{ .json = "{\"photoTakenTime\":{\"timestamp\":true}}", .photoDate = null, .logged = "Failed to parse date true from JSON file " },
        .{ .json = "{\"photoTakenTime\":{\"timestamp\":\"99999999999999\"}}", .photoDate = null, .logged = "Failed to parse date 99999999999999 from JSON file " },
        .{ .json = "{\"photoTakenTime\":{\"timestamp\":{\"a\":1}}}", .photoDate = null, .logged = "Failed to parse date [object Object] from JSON file " },
        .{ .json = "{\"photoTakenTime\":\"yesterday\"}", .photoDate = null, .logged = null },
        .{ .json = "{\"photoTakenTime\":{\"timestamp\":\"\"}}", .photoDate = null, .logged = null },
        .{ .json = "[1]", .photoDate = null, .logged = null },
    };
    for (cases) |expected| {
        errdefer std.debug.print("case: {s}\n", .{expected.json});
        try test_files.writeFile(io, jsonPath, expected.json);
        var stderr_capture = std.Io.Writer.Allocating.init(allocator);
        var stdout_capture = std.Io.Writer.Allocating.init(allocator);
        console_capture.captureConsole(&stdout_capture.writer, &stderr_capture.writer);
        var verboseLog: utils.log.ConsoleLog = .{ .verbose_enabled = true };
        var verboseVtable = verboseLog.ilog().vtable.*;
        verboseVtable.verbose = verboseToStdout;
        const previousLog = utils.log.log;
        utils.log.setLog(.{ .ptr = &verboseLog, .vtable = &verboseVtable });
        const details = getVideoDetails(allocator, io, videoPath, tempDir, "video/quicktime", generator.uuidGenerator(), "video.mov");
        utils.log.setLog(previousLog);
        console_capture.endConsoleCapture();

        const result = try details;
        if (expected.photoDate) |photoDate| {
            try std.testing.expectEqualStrings(photoDate, result.photoDate.?);
        }
        else {
            try std.testing.expect(result.photoDate == null);
        }
        if (expected.logged) |logged| {
            const everything = try std.mem.concat(allocator, u8, &.{ stdout_capture.written(), stderr_capture.written() });
            try std.testing.expect(std.mem.indexOf(u8, everything, try std.mem.concat(allocator, u8, &.{ logged, jsonPath })) != null);
        }
        try std.testing.expect(result.coordinates != null);
        try std.testing.expectEqual(@as(f64, 1.5), result.coordinates.?.lat);
        try std.testing.expectEqual(@as(f64, -2.5), result.coordinates.?.lng);
    }
}

test "a JSON file beside a video that holds null fails the video, as reading a property of null does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    const tempDir = try temp_dirs.makeTempDir(allocator, io, "video-json-null");
    defer temp_dirs.removeTempDir(io, tempDir);
    var generator = try TestUuidGenerator.init(allocator);
    const videoPath = try std.fmt.allocPrint(allocator, "{s}/video.mp4", .{tempDir});
    try test_files.writeFile(io, videoPath, try test_files.readFile(allocator, io, "../test/multiple-files/test.mp4"));
    try test_files.writeFile(io, try std.fmt.allocPrint(allocator, "{s}.json", .{videoPath}), "null");

    try std.testing.expectError(error.Thrown, getVideoDetails(allocator, io, videoPath, tempDir, "video/mp4", generator.uuidGenerator(), "video.mp4"));
    try std.testing.expectEqualStrings("null is not an object (evaluating 'photoData.photoTakenTime')", utils.errors.lastErrorMessage());
}

test "getVideoDetails refuses a content type that is not a video" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var generator = try TestUuidGenerator.init(allocator);

    try std.testing.expectError(error.Thrown, getVideoDetails(allocator, io, "../test/multiple-files/test.mp4", "unused", "application/octet-stream", generator.uuidGenerator(), "test.mp4"));
    try std.testing.expectEqualStrings("Unsupported file type: application/octet-stream", utils.errors.lastErrorMessage());
}
