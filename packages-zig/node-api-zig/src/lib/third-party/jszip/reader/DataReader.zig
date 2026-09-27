//
// Port of JSZip 3.10.1 lib/reader/DataReader.js, with the methods of ArrayReader.js, Uint8ArrayReader.js and
// NodeBufferReader.js that the reader JSZip picks for a Node Buffer (readerFor.js) uses.
//
// JSZip (c) 2009-2016 Stuart Knightley, David Duponchel, Franz Buchinger, António Afonso, MIT license.
//

const std = @import("std");
const utils_zig = @import("utils-zig");
const errors = utils_zig.errors;

//
// JavaScript's `(result << 8) + byte` for the running value of readInt: the value is converted to a 32-bit integer
// (ToInt32), shifted left by 8 in 32 bits, and the byte is then added as a double (so the sum is not truncated).
// (No JavaScript counterpart: the expression is written inline in readInt.)
//
fn shiftLeftEightAndAdd(result: i64, byte: u8) i64 {
    const asUnsigned: u32 = @truncate(@as(u64, @bitCast(result)));
    const shifted: i32 = @bitCast(asUnsigned << 8);
    return @as(i64, shifted) + byte;
}

//
// JavaScript's `value >> bits` (ToInt32 then an arithmetic shift). (No JavaScript counterpart.)
//
pub fn signedShiftRight(value: i64, bits: u5) i32 {
    const asUnsigned: u32 = @truncate(@as(u64, @bitCast(value)));
    const asSigned: i32 = @bitCast(asUnsigned);
    return asSigned >> bits;
}

//
// JavaScript's `Date.UTC(year, month, day, hour, minute, second)` for the whole numbers readDate passes: the month
// and the day may be out of range and roll over into the neighbouring year or month, as they do in JavaScript.
// Returns milliseconds since the epoch. (No JavaScript counterpart.)
//
pub fn dateUtc(year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64) i64 {
    const fullYear = if (year >= 0 and year <= 99) 1900 + year else year;
    const yearOfMonth = fullYear + @divFloor(month, 12);
    const monthOfYear = @mod(month, 12);
    const days = daysFromCivil(yearOfMonth, monthOfYear + 1, 1) + day - 1;
    return days * 86_400_000 + ((hour * 60 + minute) * 60 + second) * 1000;
}

//
// Converts a UTC calendar date to days since 1970-01-01 (Howard Hinnant's days_from_civil algorithm).
// (No JavaScript counterpart: the arithmetic of MakeDay in the ECMAScript specification.)
//
fn daysFromCivil(yearValue: i64, month: i64, day: i64) i64 {
    const year = if (month <= 2) yearValue - 1 else yearValue;
    const era = @divFloor(year, 400);
    const yearOfEra = year - era * 400;
    const shiftedMonth = if (month > 2) month - 3 else month + 9;
    const dayOfYear = @divFloor(153 * shiftedMonth + 2, 5) + day - 1;
    const dayOfEra = yearOfEra * 365 + @divFloor(yearOfEra, 4) - @divFloor(yearOfEra, 100) + dayOfYear;
    return era * 146097 + dayOfEra - 719468;
}

//
// Reads the fields of a zip file from a Node Buffer (JSZip: DataReader, as a NodeBufferReader).
//
pub const DataReader = struct {
    // The data being read (type : see implementation).
    data: []const u8,

    // The length of the data.
    length: i64,

    // The position of the next read, relative to `zero`.
    index: i64,

    // Where the zip starts in the data (bytes before it were prepended, for example by a self extractor).
    zero: i64,

    //
    // Creates a reader over the data (JSZip: `new NodeBufferReader(data)`).
    //
    pub fn init(data: []const u8) DataReader {
        return .{
            .data = data,
            .length = @intCast(data.len),
            .index = 0,
            .zero = 0,
        };
    }

    //
    // Check that the offset will not go too far.
    //
    pub fn checkOffset(self: *DataReader, offset: i64) !void {
        try self.checkIndex(self.index + offset);
    }

    //
    // Check that the specified index will not be too far.
    //
    pub fn checkIndex(self: *DataReader, newIndex: i64) !void {
        if (self.length < self.zero + newIndex or newIndex < 0) {
            return errors.throwError("End of data reached (data length = {d}, asked index = {d}). Corrupted zip ?", .{ self.length, newIndex });
        }
    }

    //
    // Change the index.
    //
    pub fn setIndex(self: *DataReader, newIndex: i64) !void {
        try self.checkIndex(newIndex);
        self.index = newIndex;
    }

    //
    // Skip the next n bytes.
    //
    pub fn skip(self: *DataReader, count: i64) !void {
        try self.setIndex(self.index + count);
    }

    //
    // Get the byte at the specified index (ArrayReader.byteAt).
    //
    pub fn byteAt(self: *DataReader, byteIndex: i64) u8 {
        return self.data[@intCast(self.zero + byteIndex)];
    }

    //
    // Get the next number with a given byte size.
    //
    pub fn readInt(self: *DataReader, size: i64) !i64 {
        var result: i64 = 0;
        try self.checkOffset(size);
        var byteIndex = self.index + size - 1;
        while (byteIndex >= self.index) : (byteIndex -= 1) {
            result = shiftLeftEightAndAdd(result, self.byteAt(byteIndex));
        }
        self.index += size;
        return result;
    }

    //
    // Get the next string with a given byte size (a binary string: one character per byte, which Zig keeps as the
    // bytes themselves).
    //
    pub fn readString(self: *DataReader, size: i64) ![]const u8 {
        return self.readData(size);
    }

    //
    // Get raw data without conversion, <size> bytes (NodeBufferReader.readData).
    //
    pub fn readData(self: *DataReader, size: i64) ![]const u8 {
        try self.checkOffset(size);
        const start: usize = @intCast(self.zero + self.index);
        const result = self.data[start .. start + @as(usize, @intCast(size))];
        self.index += size;
        return result;
    }

    //
    // Find the last occurrence of a zip signature (4 bytes) (ArrayReader.lastIndexOfSignature).
    //
    pub fn lastIndexOfSignature(self: *DataReader, sig: []const u8) i64 {
        var byteIndex = self.length - 4;
        while (byteIndex >= 0) : (byteIndex -= 1) {
            const position: usize = @intCast(byteIndex);
            if (self.data[position] == sig[0] and self.data[position + 1] == sig[1] and self.data[position + 2] == sig[2] and self.data[position + 3] == sig[3]) {
                return byteIndex - self.zero;
            }
        }

        return -1;
    }

    //
    // Read the signature (4 bytes) at the current position and compare it with sig (ArrayReader.readAndCheckSignature).
    //
    pub fn readAndCheckSignature(self: *DataReader, sig: []const u8) !bool {
        const data = try self.readData(4);
        return sig[0] == data[0] and sig[1] == data[1] and sig[2] == data[2] and sig[3] == data[3];
    }

    //
    // Get the next date (milliseconds since the epoch, like the time of a JavaScript Date).
    //
    pub fn readDate(self: *DataReader) !i64 {
        const dostime = try self.readInt(4);
        return dateUtc(
            (signedShiftRight(dostime, 25) & 0x7f) + 1980, // year
            (signedShiftRight(dostime, 21) & 0x0f) - 1, // month
            signedShiftRight(dostime, 16) & 0x1f, // day
            signedShiftRight(dostime, 11) & 0x1f, // hour
            signedShiftRight(dostime, 5) & 0x3f, // minute
            (signedShiftRight(dostime, 0) & 0x1f) << 1, // second
        );
    }
};
