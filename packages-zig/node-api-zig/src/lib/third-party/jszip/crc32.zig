//
// Port of JSZip 3.10.1 lib/crc32.js: the CRC-32 (IEEE) of a buffer.
//
// JSZip (c) 2009-2016 Stuart Knightley, David Duponchel, Franz Buchinger, António Afonso, MIT license.
//
// JSZip computes the standard CRC-32 of the zip format with a lookup table and returns it as a signed 32-bit
// integer (`crc ^ (-1)`). Zig's std.hash.Crc32 is the same CRC; the value is returned as the unsigned 32-bit pattern,
// which is what DataReader.readInt's signed reading of the stored CRC compares equal to bit for bit.
//

const std = @import("std");

//
// The CRC-32 of the input.
//
pub fn crc32wrapper(input: []const u8) u32 {
    return std.hash.Crc32.hash(input);
}
