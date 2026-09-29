const std = @import("std");
const builtin = @import("builtin");
const tools = @import("tools-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const Video = tools.Video;

//
// A directory holding a fake ffprobe, which prints a JSON file whatever it is asked, and a fake ffmpeg, which writes
// its arguments to a file. It is the only entry of PATH while the test runs.
//
const FakeFfmpegDirectory = struct {
    // Path of the directory, relative to the current directory.
    path: []const u8,

    // Absolute path of the directory.
    absolutePath: []const u8,

    // The environment passed to the tools (PATH points at the directory).
    environMap: std.process.Environ.Map,

    //
    // Creates the directory with the fake tools, ffprobe printing the given JSON, and makes PATH point at it.
    //
    fn create(self: *FakeFfmpegDirectory, allocator: std.mem.Allocator, io: std.Io, probeJson: []const u8) !void {
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);
        self.path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/fake-ffmpeg-{x}", .{std.mem.readInt(u64, &random_bytes, .little)});
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, self.path);
        self.absolutePath = try cwd.realPathFileAlloc(io, self.path, allocator);
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/probe.json", .{self.path}), .data = probeJson });
        const probePath = try std.fmt.allocPrint(allocator, "{s}/probe.json", .{self.absolutePath});
        const argumentsPath = try std.fmt.allocPrint(allocator, "{s}/arguments.txt", .{self.absolutePath});
        if (builtin.os.tag == .windows) {
            try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/ffprobe.cmd", .{self.path}), .data = try std.fmt.allocPrint(allocator, "@type \"{s}\"\r\n", .{probePath}) });
            try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/ffmpeg.cmd", .{self.path}), .data = try std.fmt.allocPrint(allocator, "@echo %*> \"{s}\"\r\n", .{argumentsPath}) });
        }
        else {
            const ffprobePath = try std.fmt.allocPrint(allocator, "{s}/ffprobe", .{self.path});
            const ffmpegPath = try std.fmt.allocPrint(allocator, "{s}/ffmpeg", .{self.path});
            try cwd.writeFile(io, .{ .sub_path = ffprobePath, .data = try std.fmt.allocPrint(allocator, "#!/bin/sh\nprintf '%s' '{s}'\n", .{probeJson}) });
            try cwd.writeFile(io, .{ .sub_path = ffmpegPath, .data = try std.fmt.allocPrint(allocator, "#!/bin/sh\nprintf '%s\\n' \"$*\" > '{s}'\n", .{argumentsPath}) });
            _ = try node_utils.exec.exec(allocator, io, try std.fmt.allocPrint(allocator, "chmod +x {s} {s}", .{ ffprobePath, ffmpegPath }));
        }
        self.environMap = std.process.Environ.Map.init(allocator);
        try self.environMap.put("PATH", self.absolutePath);
        node_utils.process_env.setEnvironMap(&self.environMap);
    }

    //
    // Reads the arguments the fake ffmpeg was run with.
    //
    fn ffmpegArguments(self: *FakeFfmpegDirectory, allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(allocator, "{s}/arguments.txt", .{self.path}), allocator, .unlimited);
        return std.mem.trimEnd(u8, text, " \r\n");
    }

    //
    // Restores the environment and deletes the directory.
    //
    fn destroy(self: *FakeFfmpegDirectory, io: std.Io) void {
        node_utils.process_env.setEnvironMap(null);
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
    }
};

//
// Reads the information of build.zig (a file that exists) as a video, with ffprobe printing the given JSON.
//
fn probe(allocator: std.mem.Allocator, probeJson: []const u8) !tools.types.AssetInfo {
    const io = std.testing.io;
    var directory: FakeFfmpegDirectory = undefined;
    try directory.create(allocator, io, probeJson);
    defer directory.destroy(io);
    var video = Video.init(allocator, io, "build.zig");
    return video.getInfo(allocator, io);
}

//
// Expects reading the information with ffprobe printing the given JSON to fail with the message.
//
fn expectProbeError(allocator: std.mem.Allocator, probeJson: []const u8, expectedMessage: []const u8) !void {
    try std.testing.expectError(error.Thrown, probe(allocator, probeJson));
    try std.testing.expectEqualStrings(expectedMessage, utils.errors.lastErrorMessage());
}

test "ffprobe output is read as the TypeScript reads it: a null stream, a missing format and an r_frame_rate that is not a string throw Bun's TypeErrors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try expectProbeError(allocator, "{\"format\":{},\"streams\":[{\"codec_type\":\"video\"},null]}", "Failed to get video info: TypeError: null is not an object (evaluating 's.codec_type')");
    try expectProbeError(allocator, "{\"streams\":[{\"codec_type\":\"video\"}]}", "Failed to get video info: TypeError: undefined is not an object (evaluating 'format.tags')");
    try expectProbeError(allocator, "{\"format\":null,\"streams\":[{\"codec_type\":\"video\"}]}", "Failed to get video info: TypeError: null is not an object (evaluating 'format.tags')");
    try expectProbeError(allocator, "{\"format\":{},\"streams\":[{\"codec_type\":\"video\",\"r_frame_rate\":30}]}", "Failed to get video info: TypeError: videoStream.r_frame_rate.split is not a function. (In 'videoStream.r_frame_rate.split(\"/\")', 'videoStream.r_frame_rate.split' is undefined)");
}

test "ffprobe output is read as the TypeScript reads it: new Date, Number, parseFloat and parseInt of any value and the spread of the tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const numbers = try probe(allocator, "{\"format\":{\"duration\":12.5,\"bit_rate\":1e21,\"tags\":{\"creation_time\":1000.7}},\"streams\":[{\"codec_type\":\"video\",\"r_frame_rate\":\"0b11/1\"}]}");
    try std.testing.expectEqual(@as(?f64, 1000), numbers.createdAt);
    try std.testing.expectEqual(@as(?f64, 3), numbers.fps);
    try std.testing.expectEqual(@as(?f64, 12.5), numbers.duration);
    try std.testing.expectEqual(@as(?f64, 1), numbers.bitrate);

    const texts = try probe(allocator, "{\"format\":{\"duration\":[\"7.5\"],\"tags\":\"ab\"},\"streams\":[{\"codec_type\":\"video\",\"r_frame_rate\":\"inf/1\"}]}");
    try std.testing.expect(std.math.isNan(texts.fps.?));
    try std.testing.expectEqual(@as(?f64, 7.5), texts.duration);
    const fields = texts.metadata.?.document.fields.items;
    try std.testing.expectEqual(@as(usize, 5), fields.len);
    try std.testing.expectEqualStrings("0", fields[0].key);
    try std.testing.expectEqualStrings("a", fields[0].value.string);
    try std.testing.expectEqualStrings("1", fields[1].key);
    try std.testing.expectEqualStrings("b", fields[1].value.string);
    try std.testing.expectEqualStrings("videoCodec", fields[2].key);

    const booleanDate = try probe(allocator, "{\"format\":{\"tags\":{\"creation_time\":true}},\"streams\":[{\"codec_type\":\"video\"}]}");
    try std.testing.expectEqual(@as(?f64, 1), booleanDate.createdAt);
}

test "extractScreenshot writes the time as a template string writes a number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var directory: FakeFfmpegDirectory = undefined;
    try directory.create(allocator, io, "{}");
    defer directory.destroy(io);
    var video = Video.init(allocator, io, "build.zig");
    _ = try video.extractScreenshot(allocator, io, "out.jpg", 1e-7);
    try std.testing.expectEqualStrings("-i build.zig -ss 1e-7 -vframes 1 -q:v 2 -y out.jpg", try directory.ffmpegArguments(allocator, io));
}
