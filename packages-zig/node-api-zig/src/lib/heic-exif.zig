const std = @import("std");
const utils = @import("utils-zig");
const errors = utils.errors;

//
// Reads the EXIF of a HEIC (or any HEIF) picture.
//
// The EXIF of a JPEG sits in an APP1 segment near its start, which is where the EXIF parser looks. A HEIF file keeps it as an item of
// type "Exif" instead, located through the file's meta box (ISO/IEC 23008-12): iinf names the items and their types, and iloc says
// where each item's bytes are, either in the file (construction method 0) or in the meta box's own idat box (method 1). The item
// starts with a four byte offset to the TIFF header within the rest of it, which Apple's files use to put "Exif\0\0" in front.
//
// What is returned is a minimal JPEG holding that EXIF in an APP1 segment, which is what the EXIF parser (a port of a third-party
// library, left as it is) reads.
//

//
// The most a JPEG APP1 segment can hold after its two byte length and the six byte "Exif\0\0" in front of the TIFF data.
//
const MAX_TIFF_LENGTH = 65535 - 2 - 6;

//
// A box of an ISO base media file: its four character type and where its content is in the buffer.
//
const IBox = struct {
    // The box's four character type.
    type: [4]u8,

    // Where the box's content starts, after its header.
    start: usize,

    // Where the box ends.
    end: usize,
};

//
// Reads the boxes in a range of a buffer one after another.
//
const BoxIterator = struct {
    // The buffer the boxes are in.
    buffer: []const u8,

    // Where the next box starts.
    position: usize,

    // Where the range the boxes are in ends.
    end: usize,

    //
    // The next box, or null at the end of the range. A box whose size does not fit in the range is an error.
    //
    fn next(self: *BoxIterator) !?IBox {
        if (self.position >= self.end) {
            return null;
        }
        if (self.end - self.position < 8) {
            return errors.throwError("A HEIF box header at offset {d} is cut short", .{self.position});
        }
        var size: u64 = std.mem.readInt(u32, self.buffer[self.position..][0..4], .big);
        var headerLength: u64 = 8;
        if (size == 1) {
            // A 64 bit size follows the type.
            if (self.end - self.position < 16) {
                return errors.throwError("A HEIF box with a 64 bit size at offset {d} is cut short", .{self.position});
            }
            size = std.mem.readInt(u64, self.buffer[self.position + 8 ..][0..8], .big);
            headerLength = 16;
        }
        else if (size == 0) {
            // The box runs to the end of what holds it.
            size = self.end - self.position;
        }
        if (size < headerLength or size > self.end - self.position) {
            return errors.throwError("The HEIF box at offset {d} says it is {d} bytes long, which does not fit", .{ self.position, size });
        }
        const box: IBox = .{
            .type = self.buffer[self.position + 4 ..][0..4].*,
            .start = self.position + @as(usize, @intCast(headerLength)),
            .end = self.position + @as(usize, @intCast(size)),
        };
        self.position = box.end;
        return box;
    }
};

//
// The boxes in a range of a buffer.
//
fn boxesIn(buffer: []const u8, start: usize, end: usize) BoxIterator {
    return .{
        .buffer = buffer,
        .position = start,
        .end = end,
    };
}

//
// The first box of a type in a range of a buffer, or null when there is none.
//
fn findBox(buffer: []const u8, start: usize, end: usize, boxType: *const [4]u8) !?IBox {
    var boxes = boxesIn(buffer, start, end);
    while (try boxes.next()) |box| {
        if (std.mem.eql(u8, &box.type, boxType)) {
            return box;
        }
    }
    return null;
}

//
// Reads big-endian numbers from a box's content, failing loudly when the content runs out.
//
const Reader = struct {
    // The buffer being read.
    buffer: []const u8,

    // Where the next number is.
    position: usize,

    // Where the content being read ends.
    end: usize,

    //
    // Reads an unsigned number of the given number of bytes: 0, 1, 2, 4 or 8.
    //
    fn number(self: *Reader, byteCount: usize) !u64 {
        if (self.end - self.position < byteCount) {
            return errors.throwError("A HEIF box ends in the middle of a field, at offset {d}", .{self.position});
        }
        var value: u64 = 0;
        for (self.buffer[self.position .. self.position + byteCount]) |byte| {
            value = (value << 8) | byte;
        }
        self.position += byteCount;
        return value;
    }

    //
    // Skips the given number of bytes.
    //
    fn skip(self: *Reader, byteCount: usize) !void {
        if (self.end - self.position < byteCount) {
            return errors.throwError("A HEIF box ends in the middle of a field, at offset {d}", .{self.position});
        }
        self.position += byteCount;
    }
};

//
// The id of the item of type "Exif" listed in an iinf box, or null when there is none.
//
fn findExifItemId(buffer: []const u8, iinf: IBox) !?u32 {
    var reader: Reader = .{
        .buffer = buffer,
        .position = iinf.start,
        .end = iinf.end,
    };
    const version = try reader.number(1);
    try reader.skip(3);
    // The entry count, which only says how many infe boxes follow, so the boxes are read to the end of the iinf instead.
    try reader.skip(if (version == 0) 2 else 4);

    var entries = boxesIn(buffer, reader.position, iinf.end);
    while (try entries.next()) |entry| {
        if (!std.mem.eql(u8, &entry.type, "infe")) {
            continue;
        }
        var entryReader: Reader = .{
            .buffer = buffer,
            .position = entry.start,
            .end = entry.end,
        };
        const entryVersion = try entryReader.number(1);
        try entryReader.skip(3);
        // Versions 0 and 1 predate item types; only versions 2 and 3 can name an Exif item.
        if (entryVersion < 2) {
            continue;
        }
        const itemId: u32 = @intCast(try entryReader.number(if (entryVersion == 2) 2 else 4));
        // The item protection index.
        try entryReader.skip(2);
        try entryReader.skip(4);
        const itemType = buffer[entryReader.position - 4 .. entryReader.position];
        if (std.mem.eql(u8, itemType, "Exif")) {
            return itemId;
        }
    }
    return null;
}

//
// Where an item's bytes are: one extent, as an offset and length in the file.
//
const IExtent = struct {
    // Where the bytes start in the file.
    offset: u64,

    // How many bytes there are.
    length: u64,
};

//
// Finds where an item's bytes are from the iloc box. The data is in the file itself (construction method 0) or in the meta box's
// idat box (method 1); a reference to another item (method 2) and an item split over several extents are errors, because the EXIF
// of a picture is neither.
//
fn findItemExtent(buffer: []const u8, iloc: IBox, idat: ?IBox, wantedItemId: u32) !?IExtent {
    var reader: Reader = .{
        .buffer = buffer,
        .position = iloc.start,
        .end = iloc.end,
    };
    const version = try reader.number(1);
    if (version > 2) {
        return errors.throwError("The HEIF iloc box has version {d}, which is newer than this reads", .{version});
    }
    try reader.skip(3);
    const sizes = try reader.number(1);
    const offsetSize: usize = @intCast(sizes >> 4);
    const lengthSize: usize = @intCast(sizes & 0x0f);
    const moreSizes = try reader.number(1);
    const baseOffsetSize: usize = @intCast(moreSizes >> 4);
    const indexSize: usize = if (version == 1 or version == 2) @intCast(moreSizes & 0x0f) else 0;
    const itemCount = try reader.number(if (version < 2) 2 else 4);

    var itemIndex: u64 = 0;
    while (itemIndex < itemCount) : (itemIndex += 1) {
        const itemId = try reader.number(if (version < 2) 2 else 4);
        var constructionMethod: u64 = 0;
        if (version == 1 or version == 2) {
            constructionMethod = (try reader.number(2)) & 0x0f;
        }
        // The data reference index, which is 0 (this file) for everything this reads.
        try reader.skip(2);
        const baseOffset = try reader.number(baseOffsetSize);
        const extentCount = try reader.number(2);
        var firstExtent: ?IExtent = null;
        var extentIndex: u64 = 0;
        while (extentIndex < extentCount) : (extentIndex += 1) {
            if (indexSize > 0) {
                try reader.skip(indexSize);
            }
            const extentOffset = try reader.number(offsetSize);
            const extentLength = try reader.number(lengthSize);
            if (extentIndex == 0) {
                firstExtent = .{
                    .offset = baseOffset + extentOffset,
                    .length = extentLength,
                };
            }
        }
        if (itemId != wantedItemId) {
            continue;
        }

        if (extentCount != 1) {
            return errors.throwError("The HEIF EXIF item is in {d} pieces, and only an item in one piece is read", .{extentCount});
        }
        var extent = firstExtent.?;
        switch (constructionMethod) {
            0 => {},
            1 => {
                const idatBox = idat orelse {
                    return errors.throwError("The HEIF EXIF item is in the meta box's idat box, which the file does not have", .{});
                };
                extent.offset += idatBox.start;
            },
            else => {
                return errors.throwError("The HEIF EXIF item is built by construction method {d}, which this does not read", .{constructionMethod});
            },
        }
        if (extent.length == 0) {
            // A length of 0 means the item runs to the end of the file.
            if (extent.offset > buffer.len) {
                return errors.throwError("The HEIF EXIF item starts at {d}, past the end of the file", .{extent.offset});
            }
            extent.length = buffer.len - extent.offset;
        }
        return extent;
    }
    return null;
}

//
// Reads the EXIF of a HEIF file from its bytes, and returns it as a minimal JPEG for the EXIF parser, or null when the file has no
// EXIF item. A file that is not laid out as HEIF says, or whose EXIF cannot be read, is an error.
//
pub fn exifAsJpeg(allocator: std.mem.Allocator, buffer: []const u8) !?[]const u8 {
    const meta = try findBox(buffer, 0, buffer.len, "meta") orelse {
        return errors.throwError("The file has no HEIF meta box", .{});
    };
    // meta is a full box: its content starts with a version and flags.
    const metaContent = meta.start + 4;
    if (metaContent > meta.end) {
        return errors.throwError("The HEIF meta box is cut short", .{});
    }
    const iinf = try findBox(buffer, metaContent, meta.end, "iinf") orelse {
        return errors.throwError("The HEIF meta box has no iinf box", .{});
    };
    const exifItemId = try findExifItemId(buffer, iinf) orelse {
        return null;
    };
    const iloc = try findBox(buffer, metaContent, meta.end, "iloc") orelse {
        return errors.throwError("The HEIF meta box has no iloc box", .{});
    };
    const idat = try findBox(buffer, metaContent, meta.end, "idat");
    const extent = try findItemExtent(buffer, iloc, idat, exifItemId) orelse {
        return errors.throwError("The HEIF iloc box does not say where the EXIF item {d} is", .{exifItemId});
    };
    if (extent.offset > buffer.len or extent.length > buffer.len - extent.offset) {
        return errors.throwError("The HEIF EXIF item at {d}, {d} bytes long, runs past the end of the file", .{ extent.offset, extent.length });
    }
    const item = buffer[@intCast(extent.offset)..@intCast(extent.offset + extent.length)];

    if (item.len < 4) {
        return errors.throwError("The HEIF EXIF item is too short to hold its TIFF header offset", .{});
    }
    const tiffHeaderOffset = std.mem.readInt(u32, item[0..4], .big);
    if (tiffHeaderOffset > item.len - 4) {
        return errors.throwError("The HEIF EXIF item's TIFF header offset {d} is past its end", .{tiffHeaderOffset});
    }
    const tiff = item[4 + tiffHeaderOffset ..];
    if (tiff.len < 2 or !(std.mem.eql(u8, tiff[0..2], "II") or std.mem.eql(u8, tiff[0..2], "MM"))) {
        return errors.throwError("The HEIF EXIF item does not start with a TIFF byte order mark where its offset says", .{});
    }
    if (tiff.len > MAX_TIFF_LENGTH) {
        return errors.throwError("The HEIF EXIF item holds {d} bytes of TIFF data, more than the {d} a JPEG APP1 segment can hold", .{ tiff.len, MAX_TIFF_LENGTH });
    }

    // Start of image, the APP1 segment (its length counts itself), "Exif\0\0", the TIFF data, and end of image.
    var jpeg: std.ArrayList(u8) = .empty;
    try jpeg.appendSlice(allocator, &.{ 0xFF, 0xD8, 0xFF, 0xE1 });
    const segmentLength: u16 = @intCast(2 + 6 + tiff.len);
    try jpeg.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, segmentLength)));
    try jpeg.appendSlice(allocator, "Exif\x00\x00");
    try jpeg.appendSlice(allocator, tiff);
    try jpeg.appendSlice(allocator, &.{ 0xFF, 0xD9 });
    return jpeg.items;
}
