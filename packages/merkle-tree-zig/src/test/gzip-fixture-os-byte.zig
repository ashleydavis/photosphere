//
// Makes Zig gzip output comparable with golden fixtures that Bun generated on Linux (no TypeScript counterpart).
// Bun's zlib writes the gzip header OS byte (OS_CODE) of the platform it runs on: 3 on Linux, 19 on macOS and 10 on
// Windows, and cloudflare-zlib-deflate.zig does the same. The golden fixtures hold 3, so on macOS and Windows the Zig
// output is normalised back to 3 before it is compared with them.
//

const std = @import("std");
const serialization_zig = @import("serialization-zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// The gzip header OS byte in the golden fixtures (OS_CODE for Unix, the platform the fixtures were generated on).
//
pub const fixture_os_code: u8 = 3;

//
// The gzip member header before the XFL and OS bytes, as Bun's zlib writes it: magic 1f 8b, method 8 (deflate), no
// flags and a zero modification time.
//
const gzip_header_prefix = [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00 };

//
// The index of the OS byte in a gzip member header.
//
const os_byte_index = 9;

//
// Returns a copy of the data in which the OS byte of every gzip member header that holds `fromOsCode` is set to
// `toOsCode`.
//
pub fn replaceGzipOsBytes(allocator: std.mem.Allocator, data: []const u8, fromOsCode: u8, toOsCode: u8) ![]u8 {
    const replaced = try allocator.dupe(u8, data);
    var index: usize = 0;
    while (index + os_byte_index < replaced.len) : (index += 1) {
        if (std.mem.startsWith(u8, replaced[index..], &gzip_header_prefix) and replaced[index + os_byte_index] == fromOsCode) {
            replaced[index + os_byte_index] = toOsCode;
        }
    }
    return replaced;
}

//
// Returns a copy of the Zig output in which the OS byte of every gzip member header is set back from this platform's
// OS_CODE to the Linux value the golden fixtures hold. On Linux the copy equals the data.
//
pub fn normaliseGzipOsBytes(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    return replaceGzipOsBytes(allocator, data, serialization_zig.cloudflare_zlib_deflate.os_code, fixture_os_code);
}

//
// Returns a copy of a file written by serialization save ([data][SHA-256 checksum of data]) in which the gzip OS bytes
// of the data are normalised by normaliseGzipOsBytes and the checksum is computed again over the normalised data, as
// Bun on Linux would have written it.
//
pub fn normaliseSavedFileGzipOsBytes(allocator: std.mem.Allocator, fileBytes: []const u8) ![]u8 {
    const dataLength = fileBytes.len - Sha256.digest_length;
    const normalised = try normaliseGzipOsBytes(allocator, fileBytes);
    Sha256.hash(normalised[0..dataLength], normalised[dataLength..][0..Sha256.digest_length], .{});
    return normalised;
}
