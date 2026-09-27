//
// Port of exif-parser 0.1.12 (lib/bufferstream.js): reads numbers and strings from a Node Buffer.
//
// Positions are signed, as in JavaScript, where a section length read from the file can go negative.
// A read outside the buffer fails like Node's `buffer.readUInt8` and friends, which throw a RangeError.
//

const std = @import("std");

//
// The error a read outside the buffer gives (Node: `RangeError [ERR_OUT_OF_RANGE]`, or
// `ERR_BUFFER_OUT_OF_BOUNDS`).
//
pub const BufferStreamError = error{OutOfRange};

//
// A position in a stream to open other streams from (TypeScript: the object `mark()` returns).
//
pub const IMarker = struct {
    // The stream the mark was taken on. Its end and byte order are read when a stream is opened, not when the
    // mark is taken (TypeScript: the closure over `self`), and a TIFF header changes the byte order after the mark.
    stream: *const BufferStream,

    // The offset of the mark.
    offset: i64,

    //
    // Opens a stream at an offset from the mark.
    //
    pub fn openWithOffset(self: IMarker, offsetFromMark: i64) BufferStream {
        const offset = offsetFromMark + self.offset;
        return BufferStream.init(self.stream.buffer, offset, self.stream.endPosition - offset, self.stream.bigEndian);
    }
};

//
// Reads values from a buffer, moving forward as it goes.
//
pub const BufferStream = struct {
    // The buffer being read.
    buffer: []const u8,

    // The position of the next read.
    offset: i64,

    // The end of the part of the buffer this stream reads.
    endPosition: i64,

    // True when numbers are big endian.
    bigEndian: bool,

    //
    // Creates a stream (TypeScript: `new BufferStream(buffer, offset, length, bigEndian)`).
    //
    pub fn init(buffer: []const u8, offset: i64, length: i64, bigEndian: bool) BufferStream {
        return .{
            .buffer = buffer,
            .offset = offset,
            .endPosition = offset + length,
            .bigEndian = bigEndian,
        };
    }

    //
    // Sets the byte order of the numbers.
    //
    pub fn setBigEndian(self: *BufferStream, bigEndian: bool) void {
        self.bigEndian = bigEndian;
    }

    //
    // The bytes of a read of `size` bytes at the current position, or an error when they are not all in the
    // buffer.
    //
    fn bytesAt(self: *BufferStream, size: usize) BufferStreamError![]const u8 {
        if (self.offset < 0 or self.offset + @as(i64, @intCast(size)) > @as(i64, @intCast(self.buffer.len))) {
            return error.OutOfRange;
        }
        const start: usize = @intCast(self.offset);
        return self.buffer[start .. start + size];
    }

    //
    // Reads an unsigned integer of the given type in the stream's byte order.
    //
    fn nextInteger(self: *BufferStream, comptime T: type) BufferStreamError!T {
        const bytes = try self.bytesAt(@sizeOf(T));
        const value = std.mem.readInt(T, bytes[0..@sizeOf(T)], if (self.bigEndian) .big else .little);
        self.offset += @sizeOf(T);
        return value;
    }

    //
    // Reads an unsigned byte.
    //
    pub fn nextUInt8(self: *BufferStream) BufferStreamError!u8 {
        return self.nextInteger(u8);
    }

    //
    // Reads a signed byte.
    //
    pub fn nextInt8(self: *BufferStream) BufferStreamError!i8 {
        return self.nextInteger(i8);
    }

    //
    // Reads an unsigned 16-bit integer.
    //
    pub fn nextUInt16(self: *BufferStream) BufferStreamError!u16 {
        return self.nextInteger(u16);
    }

    //
    // Reads an unsigned 32-bit integer.
    //
    pub fn nextUInt32(self: *BufferStream) BufferStreamError!u32 {
        return self.nextInteger(u32);
    }

    //
    // Reads a signed 16-bit integer.
    //
    pub fn nextInt16(self: *BufferStream) BufferStreamError!i16 {
        return self.nextInteger(i16);
    }

    //
    // Reads a signed 32-bit integer.
    //
    pub fn nextInt32(self: *BufferStream) BufferStreamError!i32 {
        return self.nextInteger(i32);
    }

    //
    // Reads a 32-bit float.
    //
    pub fn nextFloat(self: *BufferStream) BufferStreamError!f32 {
        return @bitCast(try self.nextInteger(u32));
    }

    //
    // Reads a 64-bit float.
    //
    pub fn nextDouble(self: *BufferStream) BufferStreamError!f64 {
        return @bitCast(try self.nextInteger(u64));
    }

    //
    // The bytes of the buffer from the current position for `length` bytes, clamped to the buffer like
    // `buffer.slice` and `buffer.toString(encoding, start, end)` clamp their range.
    //
    fn clampedRange(self: *BufferStream, length: i64) []const u8 {
        const bufferLength: i64 = @intCast(self.buffer.len);
        const start = std.math.clamp(self.offset, 0, bufferLength);
        const end = std.math.clamp(self.offset + length, start, bufferLength);
        return self.buffer[@intCast(start)..@intCast(end)];
    }

    //
    // Reads raw bytes (TypeScript: `nextBuffer`).
    //
    pub fn nextBuffer(self: *BufferStream, length: i64) []const u8 {
        const value = self.clampedRange(length);
        self.offset += length;
        return value;
    }

    //
    // The number of bytes left to read.
    //
    pub fn remainingLength(self: BufferStream) i64 {
        return self.endPosition - self.offset;
    }

    //
    // Reads a string, decoded as UTF-8 with ill-formed sequences replaced by U+FFFD
    // (TypeScript: `buffer.toString('utf8', start, end)`).
    //
    pub fn nextString(self: *BufferStream, allocator: std.mem.Allocator, length: i64) ![]const u8 {
        const bytes = self.clampedRange(length);
        const value = try std.fmt.allocPrint(allocator, "{f}", .{std.unicode.fmtUtf8(bytes)});
        self.offset += length;
        return value;
    }

    //
    // Marks the current position.
    //
    pub fn mark(self: *const BufferStream) IMarker {
        return .{
            .stream = self,
            .offset = self.offset,
        };
    }

    //
    // The distance from a mark to the current position.
    //
    pub fn offsetFrom(self: BufferStream, marker: IMarker) i64 {
        return self.offset - marker.offset;
    }

    //
    // Moves forward (or back, for a negative amount).
    //
    pub fn skip(self: *BufferStream, amount: i64) void {
        self.offset += amount;
    }

    //
    // Opens a stream over part of this one.
    //
    pub fn branch(self: BufferStream, offset: i64, length: i64) BufferStream {
        return BufferStream.init(self.buffer, self.offset + offset, length, self.bigEndian);
    }
};
