//
// Port of exif-parser 0.1.12 (lib/exif.js): reads the tags of the IFD sections of an APP1 section.
//
// A tag's value is a JavaScript value (serialization-zig's BsonValue models one): a string for format 2, the raw
// bytes for format 7, undefined for format 0, and otherwise an array with one entry per component, where rationals
// (formats 5 and 10) are two-number arrays.
//

const std = @import("std");
const serialization_zig = @import("serialization-zig");
const bufferstream = @import("bufferstream.zig");
const BsonValue = serialization_zig.bson.BsonValue;
const BufferStream = bufferstream.BufferStream;
const IMarker = bufferstream.IMarker;

// The IFD sections.
pub const IFD0: u8 = 1;
pub const IFD1: u8 = 2;
pub const GPSIFD: u8 = 3;
pub const SubIFD: u8 = 4;
pub const InteropIFD: u8 = 5;

//
// The error a value of an unknown format gives (TypeScript: 'Invalid format while decoding: ' + format).
//
pub const ExifError = error{InvalidFormatWhileDecoding};

//
// A tag's value (TypeScript: the `values` of readExifTag).
//
pub const ITagValue = union(enum) {
    // A JavaScript value: a string, an array of numbers or of rationals, or undefined.
    value: BsonValue,

    // The raw bytes of a format 7 (undefined type) tag (TypeScript: a Buffer).
    buffer: []const u8,
};

//
// Reads one component of a tag's value.
//
fn readExifValue(allocator: std.mem.Allocator, format: u16, stream: *BufferStream) !BsonValue {
    return switch (format) {
        1 => .{ .number = @floatFromInt(try stream.nextUInt8()) },
        3 => .{ .number = @floatFromInt(try stream.nextUInt16()) },
        4 => .{ .number = @floatFromInt(try stream.nextUInt32()) },
        5 => blk: {
            const pair = try allocator.alloc(BsonValue, 2);
            pair[0] = .{ .number = @floatFromInt(try stream.nextUInt32()) };
            pair[1] = .{ .number = @floatFromInt(try stream.nextUInt32()) };
            break :blk .{ .array = pair };
        },
        6 => .{ .number = @floatFromInt(try stream.nextInt8()) },
        8 => .{ .number = @floatFromInt(try stream.nextUInt16()) },
        9 => .{ .number = @floatFromInt(try stream.nextUInt32()) },
        10 => blk: {
            const pair = try allocator.alloc(BsonValue, 2);
            pair[0] = .{ .number = @floatFromInt(try stream.nextInt32()) };
            pair[1] = .{ .number = @floatFromInt(try stream.nextInt32()) };
            break :blk .{ .array = pair };
        },
        11 => .{ .number = @floatCast(try stream.nextFloat()) },
        12 => .{ .number = try stream.nextDouble() },
        else => error.InvalidFormatWhileDecoding,
    };
}

//
// The size of one component of a format.
//
fn getBytesPerComponent(format: u16) i64 {
    return switch (format) {
        1, 2, 6, 7 => 1,
        3, 8 => 2,
        4, 9, 11 => 4,
        5, 10, 12 => 8,
        else => 0,
    };
}

//
// A tag as read (TypeScript: `[tagType, values, format]`).
//
pub const IExifTag = struct {
    // The tag type.
    tagType: u16,

    // The value.
    values: ITagValue,

    // The format of the value.
    format: u16,
};

//
// Reads one tag of an IFD.
//
fn readExifTag(allocator: std.mem.Allocator, tiffMarker: IMarker, stream: *BufferStream) !IExifTag {
    const tagType = try stream.nextUInt16();
    const format = try stream.nextUInt16();
    const bytesPerComponent = getBytesPerComponent(format);
    const components: i64 = try stream.nextUInt32();
    const valueBytes = bytesPerComponent * components;
    var values: ITagValue = .{ .value = .undefined };

    // if the value is bigger then 4 bytes, the value is in the data section of the IFD
    // and the value present in the tag is the offset starting from the tiff header. So we replace the stream
    // with a stream that is located at the given offset in the data section.
    var dataStream: BufferStream = undefined;
    var valueStream = stream;
    if (valueBytes > 4) {
        dataStream = tiffMarker.openWithOffset(try stream.nextUInt32());
        valueStream = &dataStream;
    }
    //we don't want to read strings as arrays
    if (format == 2) {
        var text = try valueStream.nextString(allocator, components);
        //cut off \0 characters
        if (std.mem.indexOfScalar(u8, text, 0)) |lastNull| {
            text = text[0..lastNull];
        }
        values = .{ .value = .{ .string = text } };
    }
    else if (format == 7) {
        values = .{ .buffer = valueStream.nextBuffer(components) };
    }
    else if (format != 0) {
        var items: std.ArrayList(BsonValue) = .empty;
        var component: i64 = 0;
        while (component < components) : (component += 1) {
            try items.append(allocator, try readExifValue(allocator, format, valueStream));
        }
        values = .{ .value = .{ .array = items.items } };
    }
    //since our stream is a stateful object, we need to skip remaining bytes
    //so our offset stays correct
    if (valueBytes < 4) {
        valueStream.skip(4 - valueBytes);
    }

    return .{ .tagType = tagType, .values = values, .format = format };
}

//
// Reads the tags of an IFD, passing each to the iterator.
//
fn readIFDSection(allocator: std.mem.Allocator, tiffMarker: IMarker, stream: *BufferStream, context: anytype, comptime iterator: fn (@TypeOf(context), u16, ITagValue, u16) anyerror!void) !void {
    const numberOfEntries = try stream.nextUInt16();
    var index: u32 = 0;
    while (index < numberOfEntries) : (index += 1) {
        const tag = try readExifTag(allocator, tiffMarker, stream);
        try iterator(context, tag.tagType, tag.values, tag.format);
    }
}

//
// Reads the EXIF and TIFF headers and returns the mark of the TIFF header.
//
fn readHeader(allocator: std.mem.Allocator, stream: *BufferStream) !IMarker {
    const exifHeader = try stream.nextString(allocator, 6);
    if (!std.mem.eql(u8, exifHeader, "Exif\x00\x00")) {
        return error.InvalidExifHeader;
    }

    const tiffMarker = stream.mark();
    const tiffHeader = try stream.nextUInt16();
    if (tiffHeader == 0x4949) {
        stream.setBigEndian(false);
    }
    else if (tiffHeader == 0x4D4D) {
        stream.setBigEndian(true);
    }
    else {
        return error.InvalidTiffHeader;
    }
    if (try stream.nextUInt16() != 0x002A) {
        return error.InvalidTiffData;
    }
    return tiffMarker;
}

//
// The first number of a tag's value (TypeScript: `value[0]`), or null when there is none (an empty array, or a
// character of a string, which is not a usable offset). `value[0]` of an undefined value throws a TypeError.
//
pub fn firstNumber(values: ITagValue) !?f64 {
    switch (values) {
        .value => |value| {
            switch (value) {
                .undefined => return error.TypeError,
                .array => |items| {
                    if (items.len > 0) {
                        switch (items[0]) {
                            .number => |number| return number,
                            else => return null,
                        }
                    }
                    return null;
                },
                else => return null,
            }
        },
        .buffer => |bytes| {
            if (bytes.len > 0) {
                return @floatFromInt(bytes[0]);
            }
            return null;
        },
    }
}

//
// The state passed through readIFDSection to the IFD0 and SubIFD iterators of parseTags.
//
fn IParseContext(comptime Context: type) type {
    return struct {
        // The caller's context.
        context: Context,

        // The offset of the GPS IFD, when IFD0 has one.
        gpsOffset: ?f64 = null,

        // The offset of the SubIFD, when IFD0 has one.
        subIfdOffset: ?f64 = null,

        // The offset of the Interop IFD, when the SubIFD has one.
        interopOffset: ?f64 = null,

        // The section passed to the caller's iterator for the tags of the IFD being read.
        section: u8 = IFD0,
    };
}

//
// Reads the tags of an APP1 section, passing each with its IFD section to the iterator
// (TypeScript: `parseTags(stream, iterator)`). Returns false for an APP1 section with invalid headers.
//
pub fn parseTags(allocator: std.mem.Allocator, stream: *BufferStream, context: anytype, comptime iterator: fn (@TypeOf(context), u8, u16, ITagValue, u16) anyerror!void) !bool {
    const tiffMarker = readHeader(allocator, stream) catch {
        return false; //ignore APP1 sections with invalid headers
    };
    const Context = IParseContext(@TypeOf(context));
    var state: Context = .{ .context = context };

    const Iterators = struct {
        //
        // The IFD0 iterator: keeps the GPS and SubIFD offsets, passes the other tags on.
        //
        fn ifd0(parseState: *Context, tagType: u16, value: ITagValue, format: u16) anyerror!void {
            switch (tagType) {
                0x8825 => parseState.gpsOffset = try firstNumber(value),
                0x8769 => parseState.subIfdOffset = try firstNumber(value),
                else => try iterator(parseState.context, IFD0, tagType, value, format),
            }
        }

        //
        // Passes the tags on with the section being read (TypeScript: `iterator.bind(null, section)`).
        //
        fn bound(parseState: *Context, tagType: u16, value: ITagValue, format: u16) anyerror!void {
            try iterator(parseState.context, parseState.section, tagType, value, format);
        }

        //
        // The SubIFD iterator: keeps the Interop offset, passes the other tags on as Interop tags.
        //
        fn subIfd(parseState: *Context, tagType: u16, value: ITagValue, format: u16) anyerror!void {
            if (tagType == 0xA005) {
                parseState.interopOffset = try firstNumber(value);
            }
            else {
                try iterator(parseState.context, InteropIFD, tagType, value, format);
            }
        }
    };

    var ifd0Stream = tiffMarker.openWithOffset(try stream.nextUInt32());
    try readIFDSection(allocator, tiffMarker, &ifd0Stream, &state, Iterators.ifd0);
    const ifd1Offset = try ifd0Stream.nextUInt32();
    if (ifd1Offset != 0) {
        var ifd1Stream = tiffMarker.openWithOffset(ifd1Offset);
        state.section = IFD1;
        try readIFDSection(allocator, tiffMarker, &ifd1Stream, &state, Iterators.bound);
    }

    // JavaScript truthiness of the offsets: 0, NaN and undefined skip the section.
    if (isTruthy(state.gpsOffset)) {
        var gpsStream = tiffMarker.openWithOffset(@intFromFloat(state.gpsOffset.?));
        state.section = GPSIFD;
        try readIFDSection(allocator, tiffMarker, &gpsStream, &state, Iterators.bound);
    }

    if (isTruthy(state.subIfdOffset)) {
        var subIfdStream = tiffMarker.openWithOffset(@intFromFloat(state.subIfdOffset.?));
        try readIFDSection(allocator, tiffMarker, &subIfdStream, &state, Iterators.subIfd);
    }

    if (isTruthy(state.interopOffset)) {
        var interopStream = tiffMarker.openWithOffset(@intFromFloat(state.interopOffset.?));
        state.section = InteropIFD;
        try readIFDSection(allocator, tiffMarker, &interopStream, &state, Iterators.bound);
    }
    return true;
}

//
// JavaScript truthiness of an optional number.
//
fn isTruthy(value: ?f64) bool {
    const number = value orelse return false;
    return number != 0 and !std.math.isNan(number);
}
