//
// Port of exif-parser 0.1.12 (lib/jpeg.js): walks the sections of a JPEG.
//

const std = @import("std");
const bufferstream = @import("bufferstream.zig");
const BufferStream = bufferstream.BufferStream;

//
// The width and height of an image (TypeScript: `{ height, width }`).
//
pub const IImageSize = struct {
    // The height, in pixels.
    height: u16,

    // The width, in pixels.
    width: u16,
};

//
// The name of a section type (TypeScript: `{ name, index? }`).
//
pub const ISectionName = struct {
    // The name, or null for a marker type with no name (TypeScript: undefined).
    name: ?[]const u8,

    // The index of the section within its kind, when it has one.
    index: ?u8 = null,
};

//
// The error parseSections gives when a section does not start with 0xFF.
//
pub const JpegError = error{InvalidJpegSectionOffset};

//
// Calls the iterator with each section of the JPEG up to the start of the image data
// (TypeScript: `parseSections(stream, iterator)`).
//
pub fn parseSections(stream: *BufferStream, context: anytype, comptime iterator: fn (@TypeOf(context), u8, *BufferStream) anyerror!void) !void {
    var len: i64 = 0;
    var markerType: ?u8 = null;
    stream.setBigEndian(true);
    //stop reading the stream at the SOS (Start of Stream) marker,
    //because its length is not stored in the header so we can't
    //know where to jump to. The only marker after that is just EOI (End Of Image) anyway
    while (stream.remainingLength() > 0 and markerType != 0xDA) {
        if (try stream.nextUInt8() != 0xFF) {
            return error.InvalidJpegSectionOffset;
        }
        const marker = try stream.nextUInt8();
        markerType = marker;
        //don't read size from markers that have no datas
        if ((marker >= 0xD0 and marker <= 0xD9) or marker == 0xDA) {
            len = 0;
        }
        else {
            len = @as(i64, try stream.nextUInt16()) - 2;
        }
        var sectionStream = stream.branch(0, len);
        try iterator(context, marker, &sectionStream);
        stream.skip(len);
    }
}

//
// Reads the size from a SOF section (stream should be located after SOF section size and in big endian mode, like
// passed to parseSections iterator).
//
pub fn getSizeFromSOFSection(stream: *BufferStream) !IImageSize {
    stream.skip(1);
    return .{
        .height = try stream.nextUInt16(),
        .width = try stream.nextUInt16(),
    };
}

//
// Gets the name of a section type.
//
pub fn getSectionName(markerType: u8) ISectionName {
    return switch (markerType) {
        0xD8 => .{ .name = "SOI" },
        0xC4 => .{ .name = "DHT" },
        0xDB => .{ .name = "DQT" },
        0xDD => .{ .name = "DRI" },
        0xDA => .{ .name = "SOS" },
        0xFE => .{ .name = "COM" },
        0xD9 => .{ .name = "EOI" },
        else => blk: {
            if (markerType >= 0xE0 and markerType <= 0xEF) {
                break :blk .{ .name = "APP", .index = markerType - 0xE0 };
            }
            else if (markerType >= 0xC0 and markerType <= 0xCF and markerType != 0xC4 and markerType != 0xC8 and markerType != 0xCC) {
                break :blk .{ .name = "SOF", .index = markerType - 0xC0 };
            }
            else if (markerType >= 0xD0 and markerType <= 0xD7) {
                break :blk .{ .name = "RST", .index = markerType - 0xD0 };
            }
            break :blk .{ .name = null };
        },
    };
}
