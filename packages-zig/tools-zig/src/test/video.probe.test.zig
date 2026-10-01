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

        // cmd.exe's `type` opens the name it is given itself, and it does not take a `/` as the separator before the
        // file name: `type "C:\dir/file"` fails with "The system cannot find the file specified." where a redirection
        // (`> "C:\dir/file"`) and the win32 API open the same file. The fake ffprobe is a .cmd that types the file, so
        // its path is joined with the separator of the platform it runs on.
        const probePath = try std.fs.path.join(allocator, &.{ self.absolutePath, "probe.json" });
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

        // Image detects its installation once and remembers the commands it found, so the state of the real PATH
        // (or of an earlier fake one) must not decide what a later call in this directory finds. This is what
        // FakeImageMagickDirectory in image.command.test.zig and FakeToolsDirectory in
        // tool-verification.test.zig do.
        tools.Image.resetInitialization();
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
        tools.Image.resetInitialization();
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

test "ffprobe output that is not an object, and a streams value that is not an array, throw Bun's TypeErrors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // `probeData.format` of null throws; of any other value that is not an object it is undefined, and it is
    // `probeData.streams.find` of that undefined that throws.
    try expectProbeError(allocator, "null", "Failed to get video info: TypeError: null is not an object (evaluating 'probeData.format')");
    try expectProbeError(allocator, "5", "Failed to get video info: TypeError: undefined is not an object (evaluating 'probeData.streams.find')");
    try expectProbeError(allocator, "[]", "Failed to get video info: TypeError: undefined is not an object (evaluating 'probeData.streams.find')");
    try expectProbeError(allocator, "{}", "Failed to get video info: TypeError: undefined is not an object (evaluating 'probeData.streams.find')");
    try expectProbeError(allocator, "{\"format\":{},\"streams\":null}", "Failed to get video info: TypeError: null is not an object (evaluating 'probeData.streams.find')");
    try expectProbeError(allocator, "{\"format\":{},\"streams\":\"x\"}", "Failed to get video info: TypeError: probeData.streams.find is not a function. (In 'probeData.streams.find((s) => s.codec_type === \"video\")', 'probeData.streams.find' is undefined)");
}

test "ffprobe values of every JSON type are read the way TypeScript reads them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A stream that is not an object has no codec_type, so the video stream is the one after it. A tag list spreads
    // into the metadata under its index, a null duration and an object bit rate are neither parseFloat nor parseInt
    // of a number, a creation time of 0 is falsy and a frame rate of 0 is too.
    const values = try probe(allocator, "{\"format\":{\"duration\":null,\"bit_rate\":{},\"tags\":[1,2],\"creation_time\":0},\"streams\":[1,{\"codec_type\":\"video\",\"r_frame_rate\":0}]}");
    try std.testing.expect(std.math.isNan(values.duration.?));
    try std.testing.expect(std.math.isNan(values.bitrate.?));
    try std.testing.expect(values.createdAt == null);
    try std.testing.expect(values.fps == null);
    try std.testing.expectEqual(@as(?bool, false), values.hasAudio);
    const spread = values.metadata.?.document.fields.items;
    try std.testing.expectEqual(@as(usize, 5), spread.len);
    try std.testing.expectEqualStrings("0", spread[0].key);
    try std.testing.expectEqual(@as(f64, 1), spread[0].value.number);
    try std.testing.expectEqualStrings("1", spread[1].key);
    try std.testing.expectEqual(@as(f64, 2), spread[1].value.number);
    try std.testing.expectEqualStrings("videoCodec", spread[2].key);
    try std.testing.expect(spread[2].value == .undefined);
    try std.testing.expectEqualStrings("audioCodec", spread[3].key);
    try std.testing.expect(spread[3].value == .undefined);
    try std.testing.expectEqualStrings("pixelFormat", spread[4].key);
    try std.testing.expect(spread[4].value == .undefined);

    // A whole number is a number to String() and to parseFloat, a bit rate given as a string is read as one, a frame
    // rate with no denominator is num / NaN, and a creation time past the largest Date (8.64e15 ms) is an Invalid
    // Date, whose time value is NaN.
    const numbers = try probe(allocator, "{\"format\":{\"duration\":12,\"bit_rate\":\"8000\",\"tags\":{\"creation_time\":1e21}},\"streams\":[{\"codec_type\":\"video\",\"r_frame_rate\":\"30\"}]}");
    try std.testing.expectEqual(@as(?f64, 12), numbers.duration);
    try std.testing.expectEqual(@as(?f64, 8000), numbers.bitrate);
    try std.testing.expect(std.math.isNan(numbers.createdAt.?));
    try std.testing.expect(std.math.isNan(numbers.fps.?));

    // A creation time that is not a string is read from its String(): an array of one element is that element, and
    // an object is "[object Object]", which is not a date.
    const arrayDate = try probe(allocator, "{\"format\":{\"tags\":{\"creation_time\":[\"2024-01-02T03:04:05.000000Z\"]}},\"streams\":[{\"codec_type\":\"video\"}]}");
    try std.testing.expectEqual(@as(?f64, 1704164645000), arrayDate.createdAt);
    const objectDate = try probe(allocator, "{\"format\":{\"tags\":{\"creation_time\":{}}},\"streams\":[{\"codec_type\":\"video\"}]}");
    try std.testing.expect(std.math.isNan(objectDate.createdAt.?));
}

test "the fake tools directory does not leave the detected ImageMagick installation behind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    // The real PATH, which every later test runs against.
    if (!(try tools.Image.verifyImageMagick(allocator, io)).available) {
        std.debug.print("This test needs ImageMagick installed.\n", .{});
        return error.RequiredToolsMissing;
    }

    // A PATH with no ImageMagick in it, so a detection run now finds nothing.
    var directory: FakeFfmpegDirectory = undefined;
    try directory.create(allocator, io, "{}");
    defer directory.destroy(io);
    try std.testing.expect(!(try tools.Image.verifyImageMagick(allocator, io)).available);
    try std.testing.expectEqual(tools.image.ImageMagickType.none, tools.Image.getImageMagickType());
    directory.destroy(io);

    // The fake PATH is gone, so the installation is detected again, against the real one.
    try std.testing.expect((try tools.Image.verifyImageMagick(allocator, io)).available);
    try std.testing.expect(tools.Image.getImageMagickType() != .none);
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

    // The command quotes both paths, as the TypeScript does (`ffmpeg -i "<file>" ... -y "<output>"`). /bin/sh takes
    // the quotes apart before the fake command sees the arguments, and cmd.exe hands the command line to the fake
    // .cmd exactly as it is, so on Windows the quotes are recorded too.
    const ffmpegArguments = if (builtin.os.tag == .windows)
        "-i \"build.zig\" -ss 1e-7 -vframes 1 -q:v 2 -y \"out.jpg\""
    else
        "-i build.zig -ss 1e-7 -vframes 1 -q:v 2 -y out.jpg";
    try std.testing.expectEqualStrings(ffmpegArguments, try directory.ffmpegArguments(allocator, io));
}
