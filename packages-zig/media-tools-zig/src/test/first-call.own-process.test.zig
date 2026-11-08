const std = @import("std");
const utils = @import("utils-zig");
const media_tools = @import("media-tools-zig");
const ziggy = @import("ziggy");

const image_magick = media_tools.image_magick;
const ffmpeg = media_tools.ffmpeg;

//
// The tests of a process that has called neither library yet: a program of its own (see addOwnProcessTests in build.zig), whose one
// test makes every public function of ImageMagick and FFmpeg the first call of its library, from threads started one after another
// without waiting for each other, with nothing set up before them. Whichever thread gets there first starts the library, while the
// others call it too.
//

// The video, picture and HEIC the test reads, relative to the directory the test runs in.
const test_video = "../test/multiple-files/test.mp4";
const test_picture = "../test/test.png";
const test_heic = "../test/heic/tiled.heic";

//
// A public function of the libraries, which one thread of the test calls first.
//
const IFirstCall = enum {
    // image_magick.readImageInfo.
    read_image_info,

    // image_magick.readExif.
    read_exif,

    // image_magick.resizeImage.
    resize_image,

    // image_magick.transformImage.
    transform_image,

    // image_magick.dominantColor.
    dominant_color,

    // image_magick.writeRgbImage.
    write_rgb_image,

    // image_magick.delegates.
    delegates,

    // ffmpeg.probeFile.
    probe_file,

    // ffmpeg.extractFrame.
    extract_frame,

    // ffmpeg.readPictureSize.
    read_picture_size,

    // ffmpeg.decodePicture.
    decode_picture,
};

//
// What one thread of the test found, which only that thread writes and the test reads once it has ended.
//
const IOutcome = struct {
    // The thread's call worked and gave the answer it should.
    correct: bool = false,

    // What went wrong, or null.
    failure: ?[]const u8 = null,
};

//
// One thread of the test: makes its call, with an allocator, an Io and a log of its own.
//
fn callFirst(call: IFirstCall, directory: []const u8, outcome: *IOutcome) void {
    var thread_allocator: ziggy.utils.thread_allocator.ThreadAllocator = .init;
    defer thread_allocator.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = thread_allocator.allocator();
    defer threaded.deinit();
    var arena = std.heap.ArenaAllocator.init(thread_allocator.allocator());
    defer arena.deinit();
    outcome.correct = makeCall(call, arena.allocator(), threaded.io(), directory) catch |err| {
        // Allocated with the page allocator, because the test thread reads it after this thread's allocator is gone; never freed.
        outcome.failure = std.fmt.allocPrint(std.heap.page_allocator, "{s}: {s}: {s}", .{ @tagName(call), @errorName(err), utils.errors.lastErrorMessage() }) catch @panic("out of memory");
        return;
    };
}

//
// Makes the call and says whether its answer is the one it should be.
//
fn makeCall(call: IFirstCall, allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !bool {
    const log = utils.mute_log.MuteLog.init();
    const output_path = try std.fmt.allocPrint(allocator, "{s}/{s}.out", .{ directory, @tagName(call) });
    switch (call) {
        .read_image_info => {
            const info = try image_magick.readImageInfo(allocator, log, test_picture);
            return info.width == 100 and info.height == 90;
        },
        .read_exif => {
            const tags = try image_magick.readExif(allocator, log, "../test/test.jpg");
            return std.mem.eql(u8, tags.get("Make") orelse "", "Google");
        },
        .resize_image => {
            try image_magick.resizeImage(allocator, io, log, .{
                .input_path = test_picture,
                .output_path = output_path,
                .width = 50,
                .height = null,
                .exact = false,
                .quality = null,
                .format = "PNG",
            });
            return true;
        },
        .transform_image => {
            try image_magick.transformImage(allocator, io, log, .{
                .input_path = test_picture,
                .output_path = output_path,
                .turn = .{
                    .rotate_degrees = 90,
                },
                .format = "PNG",
            });
            return true;
        },
        .dominant_color => {
            const color = try image_magick.dominantColor(allocator, log, test_picture);
            return color[0] == color[1] and color[1] == color[2];
        },
        .write_rgb_image => {
            const bytes = [_]u8{ 255, 0, 0, 0, 255, 0 };
            try image_magick.writeRgbImage(allocator, io, log, .{
                .width = 2,
                .height = 1,
                .bytes = &bytes,
            }, .{
                .source = "two pixels",
                .output_path = output_path,
                .turn = .{},
                .format = "PNG",
                .quality = 90,
            });
            return true;
        },
        .delegates => {
            return std.mem.indexOf(u8, try image_magick.delegates(), "jpeg") != null;
        },
        .probe_file => {
            const probe = try ffmpeg.probeFile(allocator, io, log, test_video);
            return probe.streams[0].width == 1280;
        },
        .extract_frame => {
            try ffmpeg.extractFrame(allocator, io, log, .{
                .input_path = test_video,
                .output_path = output_path,
                .time_seconds = 1,
                .quality = 90,
            });
            return true;
        },
        .read_picture_size => {
            const size = try ffmpeg.readPictureSize(allocator, io, log, test_heic);
            return size.width == 1000 and size.height == 700;
        },
        .decode_picture => {
            try ffmpeg.decodePicture(allocator, io, log, .{
                .input_path = test_heic,
                .output_path = output_path,
                .quality = 90,
            });
            return true;
        },
    }
}

test "every public function works as the first call of its library in the process, from threads running at once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const current_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    const directory = try std.fs.path.join(allocator, &.{ current_path, ".zig-cache", "tmp", &tmp_dir.sub_path });

    const calls = comptime std.enums.values(IFirstCall);
    var outcomes: [calls.len]IOutcome = @splat(.{});
    var threads: [calls.len]std.Thread = undefined;
    for (calls, &threads, &outcomes) |call, *thread, *outcome| {
        thread.* = try std.Thread.spawn(.{}, callFirst, .{ call, directory, outcome });
    }
    for (threads) |thread| {
        thread.join();
    }
    for (calls, outcomes) |call, outcome| {
        if (outcome.failure) |failure| {
            std.debug.print("The first call failed: {s}\n", .{failure});
            return error.TestUnexpectedResult;
        }
        if (!outcome.correct) {
            std.debug.print("The first call {s} gave the wrong answer.\n", .{@tagName(call)});
            return error.TestUnexpectedResult;
        }
    }

    // Whichever call started ImageMagick applied the security policy, once for the process.
    const c = image_magick.c;
    try std.testing.expectEqual(@as(c.MagickBooleanType, c.MagickFalse), c.IsRightsAuthorized(c.CoderPolicyDomain, c.ReadPolicyRights, "MVG"));
    try std.testing.expectEqual(@as(c.MagickBooleanType, c.MagickTrue), c.IsRightsAuthorized(c.CoderPolicyDomain, c.ReadPolicyRights, "JPEG"));
}
