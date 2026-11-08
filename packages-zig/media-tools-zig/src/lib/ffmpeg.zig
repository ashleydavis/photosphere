const std = @import("std");
const utils = @import("utils-zig");
const ILog = utils.log.ILog;
const MessageQueue = @import("ziggy").message_queue.MessageQueue;
const image_magick = @import("image-magick.zig");
// The C interface of FFmpeg's libraries (libavformat, libavcodec, libavutil and libswscale), for code and tests that need more of
// it than the functions here.
pub const c = @import("ffmpeg");

//
// FFmpeg, built into the program and called through its libraries: each function here reads a video or a picture with typed
// arguments, on whichever thread calls it, with no setup and no teardown. FFmpeg needs no start of its own since version 4.0
// (av_register_all and avcodec_register_all are gone, and the lists of formats and codecs are constant).
//
// FFmpeg's log (av_log) has one callback for the whole process, which FFmpeg keeps in an atomic (av_log_callback in
// libavutil/log.c). Every function here sets it, to the same function, logMessage, before it makes any context, so whichever is
// called first sets it, and a second setting by another thread stores the same pointer again. logMessage keeps nothing of its own
// and shares nothing: it finds where a message belongs through the context FFmpeg logs it about, whose `opaque` field (a field
// FFmpeg leaves to the caller on its format, codec and scaling contexts) the function that made the context set to a message queue
// of that call's own. FFmpeg may log on a thread of its own (a decoder's frame threads, which carry a copy of the codec context and
// its `opaque`), so the message goes through the queue, which is made for posting from any thread, as a copy of its text, and the
// calling thread takes the messages out when every context of the call has been freed and FFmpeg's threads with them. A message
// about no context of a call (a context FFmpeg made for itself, or none) goes to the console when it is an error, and is otherwise
// dropped.
//
// A function that fails puts FFmpeg's warnings and errors of the call in the error it fails with. One that works sends its errors to
// the log's errors and its warnings to the log as FFmpeg's output.
//

// The levels of FFmpeg's log (libavutil/log.h): a message at AV_LOG_ERROR or below (fatal, panic) is an error, and one at
// AV_LOG_WARNING a warning. Messages above that (information, debugging) are not kept.
const av_log_error = 16;
const av_log_warning = 24;

// FFmpeg's "no timestamp" (AV_NOPTS_VALUE in libavutil/avutil.h).
const no_timestamp: i64 = std.math.minInt(i64);

// The end of a file or of a decoder's frames (AVERROR_EOF in libavutil/error.h: FFERRTAG('E', 'O', 'F', ' ')).
const end_of_file: c_int = -@as(c_int, @bitCast(@as(u32, 'E') | (@as(u32, 'O') << 8) | (@as(u32, 'F') << 16) | (@as(u32, ' ') << 24)));

// A decoder that wants more input before it gives a frame (AVERROR(EAGAIN)).
const try_again: c_int = -@as(c_int, c.EAGAIN);

// The microseconds FFmpeg's own times are in (AV_TIME_BASE).
const time_base_microseconds: i64 = 1000000;

// FFmpeg's log functions, declared here with the va_list as a pointer, which is how it is passed on every target the program is
// built for: it is a pointer type on Windows, macOS and 32-bit x86, an array that decays to a pointer on x86-64 System V, and on
// AArch64 Linux and Android a structure larger than 16 bytes, which the calling convention passes by its address.
const ILogCallback = *const fn (?*anyopaque, c_int, [*c]const u8, ?*anyopaque) callconv(.c) void;
const av_log_set_callback = @extern(*const fn (ILogCallback) callconv(.c) void, .{
    .name = "av_log_set_callback",
});
const av_log_format_line2 = @extern(*const fn (?*anyopaque, c_int, [*c]const u8, ?*anyopaque, [*]u8, c_int, *c_int) callconv(.c) c_int, .{
    .name = "av_log_format_line2",
});

//
// The version of FFmpeg built into the program ("9.0.2").
//
pub fn version() []const u8 {
    return std.mem.span(c.av_version_info());
}

//
// A rational number, as FFmpeg keeps frame rates.
//
pub const IRational = struct {
    // The numerator.
    numerator: i32,

    // The denominator.
    denominator: i32,
};

//
// What a stream holds.
//
pub const IStreamKind = enum {
    // Pictures.
    video,

    // Sound.
    audio,

    // Anything else (subtitles, data, attachments).
    other,
};

//
// A stream of a file, as probeFile reads it.
//
pub const IProbeStream = struct {
    // What the stream holds.
    kind: IStreamKind,

    // FFmpeg's name of the codec ("h264", "aac"), or "unknown" for a codec FFmpeg does not know.
    codec_name: []const u8,

    // The width of the pictures as stored, before any rotation, or 0 for a stream that is not video.
    width: i32,

    // The height of the pictures as stored, before any rotation, or 0 for a stream that is not video.
    height: i32,

    // FFmpeg's name of the pixel format ("yuv420p"), or "unknown" when the stream names none.
    pixel_format: []const u8,

    // The stream's frame rate as FFmpeg guesses it (r_frame_rate), 0/0 when it cannot.
    frame_rate: IRational,
};

//
// A tag of a file's container ("creation_time", "major_brand").
//
pub const ITag = struct {
    // The tag's name.
    key: []const u8,

    // The tag's value.
    value: []const u8,
};

//
// What probeFile reads of a video file.
//
pub const IProbe = struct {
    // How long the file plays, in seconds, or null when FFmpeg cannot tell.
    duration_seconds: ?f64,

    // The bits a second of the whole file, or null when FFmpeg cannot tell.
    bit_rate: ?i64,

    // The container's tags, in the order the container holds them.
    tags: []const ITag,

    // The streams, in the order of the file.
    streams: []const IProbeStream,
};

//
// Reads the duration, bitrate, tags and streams of the file at the path, as ffprobe's `-show_format -show_streams` reports them.
//
pub fn probeFile(allocator: std.mem.Allocator, io: std.Io, log: ILog, path: []const u8) !IProbe {
    log.verbose(try std.fmt.allocPrint(allocator, "FFmpeg: probing {s}", .{path}));
    var call: Call = .init(allocator, io, log, "probe", path);
    defer call.deinit();
    const result = probeFileInner(&call, path);
    return call.finish(IProbe, result);
}

//
// The body of probeFile, run with the call's log in place.
//
fn probeFileInner(call: *Call, path: []const u8) !IProbe {
    const allocator = call.allocator;
    var input = try call.openInput(path);
    defer c.avformat_close_input(&input);
    const format = input.?;

    var tags: std.ArrayList(ITag) = .empty;
    var entry: [*c]const c.AVDictionaryEntry = null;
    while (true) {
        entry = c.av_dict_iterate(format.metadata, entry);
        if (entry == null) {
            break;
        }
        try tags.append(allocator, .{
            .key = try allocator.dupe(u8, std.mem.span(entry.*.key)),
            .value = try allocator.dupe(u8, std.mem.span(entry.*.value)),
        });
    }

    var streams: std.ArrayList(IProbeStream) = .empty;
    for (format.streams[0..format.nb_streams]) |stream| {
        const parameters = stream.*.codecpar.*;
        const kind: IStreamKind = switch (parameters.codec_type) {
            c.AVMEDIA_TYPE_VIDEO => .video,
            c.AVMEDIA_TYPE_AUDIO => .audio,
            else => .other,
        };
        const descriptor = c.avcodec_descriptor_get(parameters.codec_id);
        const pixel_format = c.av_get_pix_fmt_name(parameters.format);
        try streams.append(allocator, .{
            .kind = kind,
            .codec_name = try allocator.dupe(u8, if (descriptor != null) std.mem.span(descriptor.*.name) else "unknown"),
            .width = if (kind == .video) parameters.width else 0,
            .height = if (kind == .video) parameters.height else 0,
            .pixel_format = try allocator.dupe(u8, if (kind == .video and pixel_format != null) std.mem.span(pixel_format) else "unknown"),
            .frame_rate = .{
                .numerator = stream.*.r_frame_rate.num,
                .denominator = stream.*.r_frame_rate.den,
            },
        });
    }

    return .{
        .duration_seconds = if (format.duration == no_timestamp) null else @as(f64, @floatFromInt(format.duration)) / @as(f64, @floatFromInt(time_base_microseconds)),
        .bit_rate = if (format.bit_rate > 0) format.bit_rate else null,
        .tags = tags.items,
        .streams = streams.items,
    };
}

//
// Options for extractFrame.
//
pub const IExtractFrameOptions = struct {
    // The video to read.
    input_path: []const u8,

    // The picture to write, which is made or replaced.
    output_path: []const u8,

    // The time of the frame, in seconds from the start of the video. The frame written is the first whose time is this or later.
    time_seconds: f64,

    // The JPEG quality to write at, from 0 to 100.
    quality: u8,
};

//
// Writes a JPEG of one frame of the video: the first frame at or after the time, turned upright as the video says (its display
// matrix), as the `ffmpeg` program does by default. The video is sought to the key frame before the time, so only the frames from
// there are decoded.
//
pub fn extractFrame(allocator: std.mem.Allocator, io: std.Io, log: ILog, options: IExtractFrameOptions) !void {
    log.verbose(try std.fmt.allocPrint(allocator, "FFmpeg: writing the frame at {d} seconds of {s} into {s}", .{ options.time_seconds, options.input_path, options.output_path }));
    var call: Call = .init(allocator, io, log, "extract a frame from", options.input_path);
    defer call.deinit();
    const result = extractFrameInner(&call, options);
    return call.finish(void, result);
}

//
// The body of extractFrame, run with the call's log in place.
//
fn extractFrameInner(call: *Call, options: IExtractFrameOptions) !void {
    if (!std.math.isFinite(options.time_seconds) or options.time_seconds < 0) {
        return utils.errors.throwError("The time of a frame must be a number of seconds from 0, not {d}.", .{options.time_seconds});
    }
    var input = try call.openInput(options.input_path);
    defer c.avformat_close_input(&input);
    const format = input.?;
    const stream_index = c.av_find_best_stream(format, c.AVMEDIA_TYPE_VIDEO, -1, -1, null, 0);
    if (stream_index < 0) {
        return call.failWith(stream_index, "find a video stream in");
    }
    const stream = format.streams[@intCast(stream_index)];

    // The time is from the start of the file, which FFmpeg's times count from its start time.
    const start_time: i64 = if (format.start_time == no_timestamp) 0 else format.start_time;
    const target_microseconds = @as(i64, @intFromFloat(@round(options.time_seconds * @as(f64, @floatFromInt(time_base_microseconds))))) + start_time;
    const target = c.av_rescale_q(target_microseconds, .{
        .num = 1,
        .den = @intCast(time_base_microseconds),
    }, stream.*.time_base);
    // A file that cannot be sought is decoded from its start, where it is.
    if (c.av_seek_frame(format, -1, target_microseconds, c.AVSEEK_FLAG_BACKWARD) < 0) {
        call.log.verbose(try std.fmt.allocPrint(call.allocator, "FFmpeg: {s} cannot be sought, so it is decoded from its start", .{options.input_path}));
    }

    var decoder = try call.openDecoder(stream, 0);
    defer c.avcodec_free_context(&decoder);
    var frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    defer c.av_frame_free(&frame);
    var packet = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(&packet);

    var found = false;
    var flushed = false;
    while (!found and !flushed) {
        if (!try call.readPacket(format, packet)) {
            try call.check(c.avcodec_send_packet(decoder, null), "decode");
            flushed = true;
        }
        else {
            defer c.av_packet_unref(packet);
            if (packet.*.stream_index != stream_index) {
                continue;
            }
            try call.check(c.avcodec_send_packet(decoder, packet), "decode");
        }
        while (true) {
            const received = c.avcodec_receive_frame(decoder, frame);
            if (received == try_again or received == end_of_file) {
                break;
            }
            try call.check(received, "decode");
            const timestamp = frame.*.best_effort_timestamp;
            if (timestamp == no_timestamp or timestamp >= target) {
                found = true;
                break;
            }
            c.av_frame_unref(frame);
        }
    }
    if (!found) {
        return utils.errors.throwError("{s} has no frame at or after {d} seconds.", .{ options.input_path, options.time_seconds });
    }

    const pixels = try call.toRgb(frame);
    const matrix = displayMatrixOfFrame(frame) orelse displayMatrixOfSideData(stream.*.codecpar.*.coded_side_data, stream.*.codecpar.*.nb_coded_side_data);
    try image_magick.writeRgbImage(call.allocator, call.io, call.log, pixels, .{
        .source = try std.fmt.allocPrint(call.allocator, "the frame at {d} seconds of {s}", .{ options.time_seconds, options.input_path }),
        .output_path = options.output_path,
        .turn = turnOfDisplayMatrix(matrix),
        .format = "JPEG",
        .quality = options.quality,
    });
}

//
// The width and height of a picture.
//
pub const IPictureSize = struct {
    // The width, in pixels.
    width: i32,

    // The height, in pixels.
    height: i32,
};

//
// Reads the size of the HEIC or HEIF picture at the path: the size of its tile grid when the picture is one (a phone's HEIC is a grid
// of HEVC tiles, trimmed to the picture's size), otherwise the size of its first coded picture. The size is the stored one, before
// the file's rotation.
//
pub fn readPictureSize(allocator: std.mem.Allocator, io: std.Io, log: ILog, path: []const u8) !IPictureSize {
    log.verbose(try std.fmt.allocPrint(allocator, "FFmpeg: reading the size of the picture {s}", .{path}));
    var call: Call = .init(allocator, io, log, "read the size of", path);
    defer call.deinit();
    const result = readPictureSizeInner(&call, path);
    return call.finish(IPictureSize, result);
}

//
// The body of readPictureSize, run with the call's log in place.
//
fn readPictureSizeInner(call: *Call, path: []const u8) !IPictureSize {
    var input = try call.openInput(path);
    defer c.avformat_close_input(&input);
    const format = input.?;
    if (tileGridOf(format)) |grid| {
        return checkedSize(grid.width, grid.height, path);
    }
    for (format.streams[0..format.nb_streams]) |stream| {
        if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_VIDEO) {
            return checkedSize(stream.*.codecpar.*.width, stream.*.codecpar.*.height, path);
        }
    }
    return utils.errors.throwError("FFmpeg found no picture in {s}.", .{path});
}

//
// The size, which must be positive both ways.
//
fn checkedSize(width: c_int, height: c_int, path: []const u8) !IPictureSize {
    if (width <= 0 or height <= 0) {
        return utils.errors.throwError("FFmpeg gave no usable width and height ({d}x{d}) for {s}.", .{ width, height, path });
    }
    return .{
        .width = width,
        .height = height,
    };
}

//
// Options for decodePicture.
//
pub const IDecodePictureOptions = struct {
    // The HEIC or HEIF picture to read.
    input_path: []const u8,

    // The JPEG to write, which is made or replaced.
    output_path: []const u8,

    // The JPEG quality to write at, from 0 to 100.
    quality: u8,
};

//
// Decodes the HEIC or HEIF picture at the path into a JPEG of the whole picture, as the `ffmpeg` program does: the tiles of a tile
// grid decoded and put in place over the grid's background colour, the grid trimmed to the picture's size, and the picture turned
// upright as the file says (its display matrix). The JPEG has no EXIF.
//
pub fn decodePicture(allocator: std.mem.Allocator, io: std.Io, log: ILog, options: IDecodePictureOptions) !void {
    log.verbose(try std.fmt.allocPrint(allocator, "FFmpeg: decoding the picture {s} into {s}", .{ options.input_path, options.output_path }));
    var call: Call = .init(allocator, io, log, "decode", options.input_path);
    defer call.deinit();
    const result = decodePictureInner(&call, options);
    return call.finish(void, result);
}

//
// The body of decodePicture, run with the call's log in place.
//
fn decodePictureInner(call: *Call, options: IDecodePictureOptions) !void {
    var input = try call.openInput(options.input_path);
    defer c.avformat_close_input(&input);
    const format = input.?;
    var pixels: image_magick.IRgbPixels = undefined;
    var matrix: ?[9]i32 = null;
    if (tileGridOf(format)) |grid| {
        pixels = try call.decodeTileGrid(format, grid);
        matrix = displayMatrixOfSideData(grid.coded_side_data, grid.nb_coded_side_data);
    }
    else {
        const stream_index = c.av_find_best_stream(format, c.AVMEDIA_TYPE_VIDEO, -1, -1, null, 0);
        if (stream_index < 0) {
            return call.failWith(stream_index, "find a picture in");
        }
        const stream = format.streams[@intCast(stream_index)];
        var frame = try call.decodeFirstFrame(format, stream_index);
        defer c.av_frame_free(&frame);
        pixels = try call.toRgb(frame.?);
        matrix = displayMatrixOfFrame(frame.?) orelse displayMatrixOfSideData(stream.*.codecpar.*.coded_side_data, stream.*.codecpar.*.nb_coded_side_data);
    }
    try image_magick.writeRgbImage(call.allocator, call.io, call.log, pixels, .{
        .source = options.input_path,
        .output_path = options.output_path,
        .turn = turnOfDisplayMatrix(matrix),
        .format = "JPEG",
        .quality = options.quality,
    });
}

//
// The first tile grid of more than one tile among the file's stream groups, or null when it has none. FFmpeg's HEIF demuxer reports
// a picture made of tiles as a group of their streams, and a grid of one tile is that tile's stream, as the `ffmpeg` program takes it.
//
fn tileGridOf(format: *c.AVFormatContext) ?*c.AVStreamGroupTileGrid {
    if (format.nb_stream_groups == 0) {
        return null;
    }
    for (format.stream_groups[0..format.nb_stream_groups]) |group| {
        if (group.*.type == c.AV_STREAM_GROUP_PARAMS_TILE_GRID and group.*.params.tile_grid.*.nb_tiles > 1) {
            return group.*.params.tile_grid;
        }
    }
    return null;
}

//
// The display matrix FFmpeg gives the frame, or null when it gives none.
//
fn displayMatrixOfFrame(frame: *c.AVFrame) ?[9]i32 {
    const side_data = c.av_frame_get_side_data(frame, c.AV_FRAME_DATA_DISPLAYMATRIX);
    if (side_data == null or side_data.*.size < 9 * @sizeOf(i32)) {
        return null;
    }
    return matrixOf(side_data.*.data);
}

//
// The display matrix among the side data of a stream or a stream group, or null when there is none.
//
fn displayMatrixOfSideData(side_data: [*c]c.AVPacketSideData, count: c_int) ?[9]i32 {
    const entry = c.av_packet_side_data_get(side_data, count, c.AV_PKT_DATA_DISPLAYMATRIX);
    if (entry == null or entry.*.size < 9 * @sizeOf(i32)) {
        return null;
    }
    return matrixOf(entry.*.data);
}

//
// The nine 32-bit numbers of a display matrix in its bytes.
//
fn matrixOf(bytes: [*c]const u8) [9]i32 {
    var matrix: [9]i32 = undefined;
    for (&matrix, 0..) |*value, index| {
        value.* = std.mem.readInt(i32, bytes[index * 4 ..][0..4], .little);
    }
    return matrix;
}

//
// The turn the `ffmpeg` program applies for a display matrix (its autorotation, in fftools/ffmpeg_filter.c), or none for no matrix.
//
fn turnOfDisplayMatrix(matrix: ?[9]i32) image_magick.ITurn {
    const values = matrix orelse return .{};
    var copy = values;
    return turnOfRotation(values, rotationDegrees(c.av_display_rotation_get(&copy)));
}

//
// The angle the `ffmpeg` program turns a picture by for the rotation FFmpeg reads from a display matrix (get_rotation in
// fftools/cmdutils.c): the rotation's opposite, rounded to a whole degree, from 0 up to 360.
//
pub fn rotationDegrees(rotation: f64) f64 {
    var theta = -@round(rotation);
    theta -= 360 * @floor(theta / 360 + @as(f64, 0.9) / 360);
    return theta;
}

//
// The turn the `ffmpeg` program applies for a display matrix and the angle rotationDegrees gives for it (fftools/ffmpeg_filter.c):
// its transpose filter's clock, cclock, clock_flip and cclock_flip, and its hflip, vflip and rotate filters, as ImageMagick does
// them. An angle that is not a number (a matrix that is no rotation) turns nothing, as in the `ffmpeg` program.
//
pub fn turnOfRotation(matrix: [9]i32, theta: f64) image_magick.ITurn {
    if (@abs(theta - 90) < 1.0) {
        if (matrix[3] > 0) {
            return .{
                .transpose = true,
            };
        }
        return .{
            .rotate_degrees = 90,
        };
    }
    if (@abs(theta - 180) < 1.0) {
        return .{
            .flop = matrix[0] < 0,
            .flip = matrix[4] < 0,
        };
    }
    if (@abs(theta - 270) < 1.0) {
        if (matrix[3] < 0) {
            return .{
                .transverse = true,
            };
        }
        return .{
            .rotate_degrees = 270,
        };
    }
    if (@abs(theta) > 1.0) {
        return .{
            .rotate_degrees = theta,
        };
    }
    if (@abs(theta) < 1.0) {
        return .{
            .flip = matrix[4] < 0,
        };
    }
    return .{};
}

//
// A message of FFmpeg's log, taken from a call's queue.
//
const ILogMessage = struct {
    // FFmpeg's level of the message.
    level: c_int,

    // The message, as FFmpeg writes it to the standard error, with the context it is about in front ("[mov,mp4 @ 0x...] ...").
    text: []const u8,
};

//
// One call into FFmpeg: the queue FFmpeg's log posts the call's messages to, and what the call is, for its messages.
//
const Call = struct {
    // The allocator of the calling thread, which everything the call hands back is made with.
    allocator: std.mem.Allocator,

    // The Io of the calling thread.
    io: std.Io,

    // The log the call's messages go to.
    log: ILog,

    // What the call does ("probe"), for messages.
    operation: []const u8,

    // The file the call reads, for messages.
    subject: []const u8,

    // The queue logMessage posts the call's messages to, from whichever thread FFmpeg logs on. Every context the call makes points
    // at it through its `opaque`.
    queue: MessageQueue,

    //
    // Starts a call: sets FFmpeg's log callback (see the top of this file) and makes the call's queue.
    //
    fn init(allocator: std.mem.Allocator, io: std.Io, log: ILog, operation: []const u8, subject: []const u8) Call {
        av_log_set_callback(logMessage);
        return .{
            .allocator = allocator,
            .io = io,
            .log = log,
            .operation = operation,
            .subject = subject,
            .queue = MessageQueue.init(),
        };
    }

    //
    // Frees the call's queue.
    //
    fn deinit(self: *Call) void {
        self.queue.deinit();
    }

    //
    // Ends the call, once every context it made is freed: takes the messages FFmpeg logged, and either fails with them, when the call
    // failed, or sends them to the log and hands back the result.
    //
    fn finish(self: *Call, comptime T: type, result: anyerror!T) !T {
        var messages: std.ArrayList(ILogMessage) = .empty;
        while (self.queue.tryTake(self.io, self.allocator)) |message| {
            try messages.append(self.allocator, .{
                .level = @bitCast(message.from),
                .text = message.text,
            });
        }
        const value = result catch |err| {
            if (err != error.Thrown) {
                return err;
            }
            if (messages.items.len == 0) {
                return error.Thrown;
            }
            var text: std.ArrayList(u8) = .empty;
            try text.appendSlice(self.allocator, utils.errors.lastErrorMessage());
            try text.appendSlice(self.allocator, "\nFFmpeg said:");
            for (messages.items) |message| {
                try text.print(self.allocator, "\n{s}", .{message.text});
            }
            return utils.errors.throwError("{s}", .{text.items});
        };
        for (messages.items) |message| {
            if (message.level <= av_log_error) {
                self.log.@"error"(try std.fmt.allocPrint(self.allocator, "FFmpeg ({s} {s}): {s}", .{ self.operation, self.subject, message.text }));
            }
            else {
                self.log.tool("ffmpeg", .{
                    .stdout = null,
                    .stderr = try std.fmt.allocPrint(self.allocator, "{s} {s}: {s}\n", .{ self.operation, self.subject, message.text }),
                });
            }
        }
        return value;
    }

    //
    // Fails the call with FFmpeg's error, which the step failed with.
    //
    fn failWith(self: *Call, code: c_int, step: []const u8) error{Thrown} {
        var buffer: [256]u8 = undefined;
        if (c.av_strerror(code, &buffer, buffer.len) < 0) {
            return utils.errors.throwError("FFmpeg could not {s} {s}: FFmpeg error {d}.", .{ step, self.subject, code });
        }
        return utils.errors.throwError("FFmpeg could not {s} {s}: {s}.", .{ step, self.subject, std.mem.sliceTo(&buffer, 0) });
    }

    //
    // Fails the call when FFmpeg's result is an error.
    //
    fn check(self: *Call, code: c_int, step: []const u8) !void {
        if (code < 0) {
            return self.failWith(code, step);
        }
    }

    //
    // Reads the next packet of the file into the packet, and returns false at the end of the file. A file that cannot be read further
    // ends there, as it does for the `ffmpeg` program (fftools/ffmpeg_demux.c), so that the frames of a file cut short are still read;
    // the error is put among the call's messages, as an error.
    //
    fn readPacket(self: *Call, format: *c.AVFormatContext, packet: *c.AVPacket) !bool {
        const read = c.av_read_frame(format, packet);
        if (read == end_of_file) {
            return false;
        }
        if (read < 0) {
            var buffer: [256]u8 = undefined;
            const reason: []const u8 = if (c.av_strerror(read, &buffer, buffer.len) < 0) "an unknown error" else std.mem.sliceTo(&buffer, 0);
            const message = try std.fmt.allocPrint(self.allocator, "Error reading {s}, which is read no further: {s}", .{ self.subject, reason });
            try self.queue.post(self.io, @bitCast(@as(c_int, av_log_error)), message);
            return false;
        }
        return true;
    }

    //
    // Opens the file and reads enough of it to know its streams, with the call's log. The caller closes it.
    //
    fn openInput(self: *Call, path: []const u8) !?*c.AVFormatContext {
        const path_z = try self.allocator.dupeZ(u8, path);
        var format: ?*c.AVFormatContext = c.avformat_alloc_context() orelse return error.OutOfMemory;
        format.?.@"opaque" = &self.queue;
        // FFmpeg frees the context when it cannot open the file.
        try self.check(c.avformat_open_input(&format, path_z.ptr, null, null), "open");
        errdefer c.avformat_close_input(&format);
        try self.check(c.avformat_find_stream_info(format, null), "read the streams of");
        return format;
    }

    //
    // Opens a decoder of the stream, with the call's log, on the number of threads (0 for as many as FFmpeg chooses). The caller frees
    // it.
    //
    fn openDecoder(self: *Call, stream: *c.AVStream, threads: c_int) !?*c.AVCodecContext {
        const parameters = stream.codecpar;
        const decoder = c.avcodec_find_decoder(parameters.*.codec_id) orelse {
            const descriptor = c.avcodec_descriptor_get(parameters.*.codec_id);
            return utils.errors.throwError("FFmpeg has no decoder for the {s} of {s}.", .{ if (descriptor != null) std.mem.span(descriptor.*.name) else "unknown codec", self.subject });
        };
        var context: ?*c.AVCodecContext = c.avcodec_alloc_context3(decoder) orelse return error.OutOfMemory;
        errdefer c.avcodec_free_context(&context);
        try self.check(c.avcodec_parameters_to_context(context, parameters), "set up a decoder for");
        context.?.@"opaque" = &self.queue;
        context.?.pkt_timebase = stream.time_base;
        context.?.thread_count = threads;
        try self.check(c.avcodec_open2(context, decoder, null), "open a decoder for");
        return context;
    }

    //
    // Decodes the first frame of the stream, on one thread. The caller frees the frame.
    //
    fn decodeFirstFrame(self: *Call, format: *c.AVFormatContext, stream_index: c_int) !?*c.AVFrame {
        var decoder = try self.openDecoder(format.streams[@intCast(stream_index)], 1);
        defer c.avcodec_free_context(&decoder);
        var packet = c.av_packet_alloc() orelse return error.OutOfMemory;
        defer c.av_packet_free(&packet);
        var frame: ?*c.AVFrame = c.av_frame_alloc() orelse return error.OutOfMemory;
        errdefer c.av_frame_free(&frame);
        var flushed = false;
        while (true) {
            if (!flushed) {
                if (!try self.readPacket(format, packet)) {
                    try self.check(c.avcodec_send_packet(decoder, null), "decode");
                    flushed = true;
                }
                else {
                    defer c.av_packet_unref(packet);
                    if (packet.*.stream_index != stream_index) {
                        continue;
                    }
                    try self.check(c.avcodec_send_packet(decoder, packet), "decode");
                }
            }
            const received = c.avcodec_receive_frame(decoder, frame);
            if (received == try_again) {
                if (flushed) {
                    return utils.errors.throwError("FFmpeg's decoder wanted more of {s} after its end.", .{self.subject});
                }
                continue;
            }
            if (received == end_of_file) {
                return utils.errors.throwError("FFmpeg found no picture to decode in {s}.", .{self.subject});
            }
            try self.check(received, "decode");
            return frame;
        }
    }

    //
    // Decodes every tile of the grid and puts each in place on a picture of the grid's size filled with its background colour, then
    // trims the picture to the grid's picture (fftools/ffmpeg_demux.c joins them with the xstack filter and crops the result).
    //
    fn decodeTileGrid(self: *Call, format: *c.AVFormatContext, grid: *c.AVStreamGroupTileGrid) !image_magick.IRgbPixels {
        const group = groupOfGrid(format, grid);
        const coded_width: usize = try positive(grid.coded_width, "coded width", self.subject);
        const coded_height: usize = try positive(grid.coded_height, "coded height", self.subject);
        const canvas = try self.allocator.alloc(u8, coded_width * coded_height * 3);
        for (0..coded_width * coded_height) |pixel| {
            @memcpy(canvas[pixel * 3 ..][0..3], grid.background[0..3]);
        }

        // Each tile is a stream of one picture, so each is decoded from its own packet by a decoder of its own.
        var placed: usize = 0;
        var packet = c.av_packet_alloc() orelse return error.OutOfMemory;
        defer c.av_packet_free(&packet);
        while (placed < grid.nb_tiles) {
            if (!try self.readPacket(format, packet)) {
                return utils.errors.throwError("{s} ends after {d} of the {d} tiles of its picture.", .{ self.subject, placed, grid.nb_tiles });
            }
            defer c.av_packet_unref(packet);
            for (grid.offsets[0..grid.nb_tiles]) |offset| {
                const stream = group.*.streams[offset.idx];
                if (stream.*.index != packet.*.stream_index) {
                    continue;
                }
                const tile = try self.decodePacket(stream, packet);
                try placeTile(canvas, coded_width, coded_height, tile, offset.horizontal, offset.vertical);
                placed += 1;
            }
        }

        // The picture is the grid trimmed to its size, at its offset.
        const width: usize = try positive(grid.width, "width", self.subject);
        const height: usize = try positive(grid.height, "height", self.subject);
        const left: usize = @intCast(@max(grid.horizontal_offset, 0));
        const top: usize = @intCast(@max(grid.vertical_offset, 0));
        if (left + width > coded_width or top + height > coded_height) {
            return utils.errors.throwError("The {d}x{d} picture at {d},{d} of {s} is outside its {d}x{d} tile grid.", .{ width, height, left, top, self.subject, coded_width, coded_height });
        }
        const bytes = try self.allocator.alloc(u8, width * height * 3);
        for (0..height) |row| {
            @memcpy(bytes[row * width * 3 ..][0 .. width * 3], canvas[((top + row) * coded_width + left) * 3 ..][0 .. width * 3]);
        }
        return .{
            .width = width,
            .height = height,
            .bytes = bytes,
        };
    }

    //
    // Decodes the one picture of a tile's stream from its packet, on one thread.
    //
    fn decodePacket(self: *Call, stream: *c.AVStream, packet: *c.AVPacket) !image_magick.IRgbPixels {
        var decoder = try self.openDecoder(stream, 1);
        defer c.avcodec_free_context(&decoder);
        var frame: ?*c.AVFrame = c.av_frame_alloc() orelse return error.OutOfMemory;
        defer c.av_frame_free(&frame);
        try self.check(c.avcodec_send_packet(decoder, packet), "decode a tile of");
        try self.check(c.avcodec_send_packet(decoder, null), "decode a tile of");
        try self.check(c.avcodec_receive_frame(decoder, frame), "decode a tile of");
        return self.toRgb(frame.?);
    }

    //
    // The frame's picture as eight bit red, green and blue, converted by libswscale with the frame's own colour space and range.
    //
    fn toRgb(self: *Call, frame: *c.AVFrame) !image_magick.IRgbPixels {
        var scaler: ?*c.SwsContext = c.sws_alloc_context() orelse return error.OutOfMemory;
        defer c.sws_free_context(&scaler);
        scaler.?.@"opaque" = &self.queue;
        var rgb: ?*c.AVFrame = c.av_frame_alloc() orelse return error.OutOfMemory;
        defer c.av_frame_free(&rgb);
        rgb.?.format = c.AV_PIX_FMT_RGB24;
        rgb.?.width = frame.width;
        rgb.?.height = frame.height;
        try self.check(c.av_frame_get_buffer(rgb, 0), "make room for a picture of");
        try self.check(c.sws_scale_frame(scaler, rgb, frame), "convert a picture of");
        const width: usize = try positive(frame.width, "width", self.subject);
        const height: usize = try positive(frame.height, "height", self.subject);
        const bytes = try self.allocator.alloc(u8, width * height * 3);
        const stride: usize = @intCast(rgb.?.linesize[0]);
        for (0..height) |row| {
            @memcpy(bytes[row * width * 3 ..][0 .. width * 3], rgb.?.data[0][row * stride ..][0 .. width * 3]);
        }
        return .{
            .width = width,
            .height = height,
            .bytes = bytes,
        };
    }
};

//
// The stream group the tile grid is the parameters of.
//
fn groupOfGrid(format: *c.AVFormatContext, grid: *c.AVStreamGroupTileGrid) *c.AVStreamGroup {
    for (format.stream_groups[0..format.nb_stream_groups]) |group| {
        if (group.*.type == c.AV_STREAM_GROUP_PARAMS_TILE_GRID and group.*.params.tile_grid == grid) {
            return group;
        }
    }
    unreachable;
}

//
// A size of FFmpeg's, which must be positive.
//
fn positive(value: c_int, what: []const u8, subject: []const u8) !usize {
    if (value <= 0) {
        return utils.errors.throwError("FFmpeg gave a {s} of {d} for {s}.", .{ what, value, subject });
    }
    return @intCast(value);
}

//
// Copies the tile onto the canvas with its top left corner at the offset, leaving out whatever of it falls outside the canvas.
//
pub fn placeTile(canvas: []u8, canvas_width: usize, canvas_height: usize, tile: image_magick.IRgbPixels, horizontal: c_int, vertical: c_int) !void {
    if (horizontal < 0 or vertical < 0) {
        return utils.errors.throwError("A tile is placed at {d},{d}, outside its grid.", .{ horizontal, vertical });
    }
    const left: usize = @intCast(horizontal);
    const top: usize = @intCast(vertical);
    if (left >= canvas_width or top >= canvas_height) {
        return;
    }
    const columns = @min(tile.width, canvas_width - left);
    const rows = @min(tile.height, canvas_height - top);
    for (0..rows) |row| {
        @memcpy(canvas[((top + row) * canvas_width + left) * 3 ..][0 .. columns * 3], tile.bytes[row * tile.width * 3 ..][0 .. columns * 3]);
    }
}

//
// The message queue of the call the context FFmpeg logs about belongs to, or null when it belongs to none: the `opaque` of a format,
// codec or scaling context a call made, or of the context a part of one of those (a demuxer's or decoder's own data) names as its
// parent through its class.
//
fn queueOfContext(context: ?*anyopaque) ?*MessageQueue {
    var current = context;
    while (current) |pointer| {
        const class_pointer: *const ?*const c.AVClass = @ptrCast(@alignCast(pointer));
        const class = class_pointer.* orelse return null;
        if (class == c.avformat_get_class()) {
            const format: *c.AVFormatContext = @ptrCast(@alignCast(pointer));
            return @ptrCast(@alignCast(format.@"opaque"));
        }
        if (class == c.avcodec_get_class()) {
            const codec: *c.AVCodecContext = @ptrCast(@alignCast(pointer));
            return @ptrCast(@alignCast(codec.@"opaque"));
        }
        if (class == c.sws_get_class()) {
            const scaler: *c.SwsContext = @ptrCast(@alignCast(pointer));
            return @ptrCast(@alignCast(scaler.@"opaque"));
        }
        if (class.parent_log_context_offset == 0) {
            return null;
        }
        const parent: *const ?*anyopaque = @ptrCast(@alignCast(@as([*]u8, @ptrCast(pointer)) + @as(usize, @intCast(class.parent_log_context_offset))));
        current = parent.*;
    }
    return null;
}

//
// The longest line of FFmpeg's log logMessage keeps, and the buffer a message is made in: the line and what logMessage adds.
//
const line_size = 4096;
const message_buffer_size = line_size + " [cut short]".len;

//
// FFmpeg's log callback, called on whichever thread logs (see the top of this file). A warning or an error goes, written as FFmpeg
// writes it to the standard error, to the queue of the call the context it is about belongs to; an error of no call goes to the
// console. A message longer than the line it is written into is cut short, and says so.
//
fn logMessage(avcl: ?*anyopaque, level: c_int, fmt: [*c]const u8, vl: ?*anyopaque) callconv(.c) void {
    // As av_log_default_callback (libavutil/log.c) does, the colour FFmpeg may give a message in the bits above the level is dropped
    // before the level is compared.
    const plain_level = if (level >= 0) level & 0xff else level;
    if (plain_level > av_log_warning) {
        return;
    }
    const queue = queueOfContext(avcl);
    if (queue == null and plain_level > av_log_error) {
        return;
    }
    var line: [line_size]u8 = undefined;
    var print_prefix: c_int = 1;
    const length = av_log_format_line2(avcl, level, fmt, vl, &line, line.len, &print_prefix);
    const console_log = utils.log.ConsoleLog.init();
    if (length < 0) {
        console_log.@"error"("A message of FFmpeg's log could not be written out.");
        return;
    }
    const written: usize = @min(@as(usize, @intCast(length)), line.len - 1);
    const text = std.mem.trimEnd(u8, line[0..written], "\r\n");
    if (text.len == 0) {
        return;
    }
    // The message is made in a buffer on the calling thread's stack, because this runs on whichever thread logs.
    var message_buffer: [message_buffer_size]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buffer, "{s}{s}", .{ text, if (written < length) " [cut short]" else "" }) catch @panic("a message of FFmpeg is longer than its buffer");
    const call_queue = queue orelse {
        console_log.@"error"(message);
        return;
    };
    // The thread may be one of FFmpeg's own, which has no Io, so it posts with an Io of its own, which allocates nothing for a post, so
    // its allocator is a buffer on the stack.
    var io_buffer: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&io_buffer);
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = fixed.allocator();
    defer threaded.deinit();
    call_queue.post(threaded.io(), @bitCast(plain_level), message) catch @panic("out of memory logging a message of FFmpeg");
}
