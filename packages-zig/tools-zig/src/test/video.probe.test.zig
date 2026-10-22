const std = @import("std");
const tools = @import("tools-zig");
const utils = @import("utils-zig");
const fake_tool_runner = @import("fake-tool-runner.zig");
const Video = tools.Video;
const FakeToolRunner = fake_tool_runner.FakeToolRunner;

//
// Reads the information of a video that exists (the checked in test.mp4), with ffprobe printing the given JSON.
//
fn probe(allocator: std.mem.Allocator, probeJson: []const u8) !tools.types.AssetInfo {
    var fakeTools = FakeToolRunner.init(allocator, &.{
        .{
            .name = "ffprobe",
            .output = probeJson,
        },
    });
    var video = Video.init("../test/multiple-files/test.mp4");
    return video.getInfo(allocator, std.testing.io, fakeTools.runner());
}

//
// Expects reading the information with ffprobe printing the given JSON to fail with the message.
//
fn expectProbeError(allocator: std.mem.Allocator, probeJson: []const u8, expectedMessage: []const u8) !void {
    try std.testing.expectError(error.Thrown, probe(allocator, probeJson));
    try std.testing.expectEqualStrings(expectedMessage, utils.errors.lastErrorMessage());
}

test "ffprobe output with a null stream, a missing format and an r_frame_rate that is not a string throws TypeErrors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try expectProbeError(allocator, "{\"format\":{},\"streams\":[{\"codec_type\":\"video\"},null]}", "Failed to get video info: TypeError: null is not an object (evaluating 's.codec_type')");
    try expectProbeError(allocator, "{\"streams\":[{\"codec_type\":\"video\"}]}", "Failed to get video info: TypeError: undefined is not an object (evaluating 'format.tags')");
    try expectProbeError(allocator, "{\"format\":null,\"streams\":[{\"codec_type\":\"video\"}]}", "Failed to get video info: TypeError: null is not an object (evaluating 'format.tags')");
    try expectProbeError(allocator, "{\"format\":{},\"streams\":[{\"codec_type\":\"video\",\"r_frame_rate\":30}]}", "Failed to get video info: TypeError: videoStream.r_frame_rate.split is not a function. (In 'videoStream.r_frame_rate.split(\"/\")', 'videoStream.r_frame_rate.split' is undefined)");
}

test "ffprobe output is read with new Date, Number, parseFloat and parseInt of any value and the spread of the tags" {
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

test "ffprobe output that is not an object, and a streams value that is not an array, throw TypeErrors" {
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

test "ffprobe values of every JSON type are read" {
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

//
// A boolean is the text "true" or "false" to String() and so is not a number to parseFloat, an array puts a comma
// between its elements (so a leading null gives ",7.5", which parseFloat cannot read), and a tag list that is a string
// spreads into one entry per UTF-16 code unit, so that a character outside the BMP gives two entries, each a U+FFFD
// when written as UTF-8. Checked against Node: parseFloat(String(true)) and parseFloat(String([null, 7.5])) are NaN,
// and Object.entries({ ..."a😀b" }) give the keys "0" to "3".
//
test "ffprobe values that are booleans, arrays with a null and strings with characters outside the BMP are read like TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const booleanDuration = try probe(allocator, "{\"format\":{\"duration\":true},\"streams\":[{\"codec_type\":\"video\"}]}");
    try std.testing.expect(std.math.isNan(booleanDuration.duration.?));

    const nullFirst = try probe(allocator, "{\"format\":{\"duration\":[null,7.5]},\"streams\":[{\"codec_type\":\"video\"}]}");
    try std.testing.expect(std.math.isNan(nullFirst.duration.?));

    const emoji = try probe(allocator, "{\"format\":{\"tags\":\"a\u{1F600}b\"},\"streams\":[{\"codec_type\":\"video\"}]}");
    const fields = emoji.metadata.?.document.fields.items;
    try std.testing.expectEqualStrings("0", fields[0].key);
    try std.testing.expectEqualStrings("a", fields[0].value.string);
    try std.testing.expectEqualStrings("1", fields[1].key);
    try std.testing.expectEqualStrings("\u{FFFD}", fields[1].value.string);
    try std.testing.expectEqualStrings("2", fields[2].key);
    try std.testing.expectEqualStrings("\u{FFFD}", fields[2].value.string);
    try std.testing.expectEqualStrings("3", fields[3].key);
    try std.testing.expectEqualStrings("b", fields[3].value.string);
    try std.testing.expectEqualStrings("videoCodec", fields[4].key);
}

test "extractScreenshot writes the time the way JavaScript writes a number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fakeTools = FakeToolRunner.init(allocator, &.{
        .{
            .name = "ffmpeg",
            .output = "",
        },
    });
    var video = Video.init("../test/multiple-files/test.mp4");
    _ = try video.extractScreenshot(allocator, io, fakeTools.runner(), "out.jpg", 1e-7);

    // The command quotes both paths (`ffmpeg -i "<file>" ... -y "<output>"`), and the runner gets the words with the
    // quotes taken off.
    try std.testing.expectEqualStrings("-i ../test/multiple-files/test.mp4 -ss 1e-7 -vframes 1 -q:v 2 -y out.jpg", try fakeTools.argumentsOf("ffmpeg"));
}

test "verifyFfprobe and verifyFfmpeg report the built-in tool failing with no install advice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    // A runner whose ffprobe and ffmpeg both fail.
    var fakeTools = FakeToolRunner.init(allocator, &.{});

    const ffprobeStatus = try Video.verifyFfprobe(allocator, io, fakeTools.runner());
    try std.testing.expect(!ffprobeStatus.available);
    try std.testing.expect(ffprobeStatus.version == null);
    try std.testing.expectEqualStrings("The ffprobe built into the program did not run: Error: Command failed: ffprobe -version\n", ffprobeStatus.@"error".?);

    const ffmpegStatus = try Video.verifyFfmpeg(allocator, io, fakeTools.runner());
    try std.testing.expect(!ffmpegStatus.available);
    try std.testing.expect(ffmpegStatus.version == null);
    try std.testing.expectEqualStrings("The ffmpeg built into the program did not run: Error: Command failed: ffmpeg -version\n", ffmpegStatus.@"error".?);
}

// String() of an array joins its elements with commas, so parseFloat and parseInt read up to the first comma; and a string spreads
// its UTF-16 code units, so a character outside the BMP gives two entries, each a lone surrogate written as U+FFFD.
test "ffprobe arrays of several values are read from their joined text and a tag string spreads its code units" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const values = try probe(allocator, "{\"format\":{\"duration\":[\"7.5\",\"x\"],\"bit_rate\":[\"12\",\"34\"],\"tags\":\"a\u{1F600}\"},\"streams\":[{\"codec_type\":\"video\"}]}");
    try std.testing.expectEqual(@as(?f64, 7.5), values.duration);
    try std.testing.expectEqual(@as(?f64, 12), values.bitrate);
    const fields = values.metadata.?.document.fields.items;
    try std.testing.expectEqual(@as(usize, 6), fields.len);
    try std.testing.expectEqualStrings("0", fields[0].key);
    try std.testing.expectEqualStrings("a", fields[0].value.string);
    try std.testing.expectEqualStrings("1", fields[1].key);
    try std.testing.expectEqualStrings("\u{FFFD}", fields[1].value.string);
    try std.testing.expectEqualStrings("2", fields[2].key);
    try std.testing.expectEqualStrings("\u{FFFD}", fields[2].value.string);
    try std.testing.expectEqualStrings("videoCodec", fields[3].key);
}
