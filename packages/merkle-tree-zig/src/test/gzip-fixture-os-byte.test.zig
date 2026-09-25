//
// Tests for the gzip OS byte normalisation used to compare Zig output with golden fixtures (no TypeScript counterpart).
//

const std = @import("std");
const serialization_zig = @import("serialization-zig");
const gzip_fixture_os_byte = @import("gzip-fixture-os-byte.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

test "replaceGzipOsBytes sets the OS byte of every gzip member header that holds the given code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const data = [_]u8{ 0xaa, 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x13, 0x03, 0x00, 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x13, 0x55 };
    const expected = [_]u8{ 0xaa, 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03, 0x03, 0x00, 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03, 0x55 };
    const replaced = try gzip_fixture_os_byte.replaceGzipOsBytes(allocator, &data, 19, 3);
    try std.testing.expectEqualSlices(u8, &expected, replaced);

    // The input is left unchanged.
    try std.testing.expectEqual(@as(u8, 0x13), data[10]);
}

test "replaceGzipOsBytes leaves OS bytes with other codes and bytes that are not a gzip header unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const data = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x0a,
        0x1f, 0x8b, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x02, 0x13,
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    };
    try std.testing.expectEqualSlices(u8, &data, try gzip_fixture_os_byte.replaceGzipOsBytes(allocator, &data, 19, 3));
}

test "normaliseGzipOsBytes turns gzipLevel9 output into the bytes Bun writes on Linux" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expected = [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03, 0x4b, 0x04, 0x00, 0x43, 0xbe, 0xb7, 0xe8, 0x01, 0x00, 0x00, 0x00 };
    const compressed = try serialization_zig.cloudflare_zlib_deflate.gzipLevel9(allocator, "a");
    try std.testing.expectEqualSlices(u8, &expected, try gzip_fixture_os_byte.normaliseGzipOsBytes(allocator, compressed));
}

test "normaliseSavedFileGzipOsBytes normalises the gzip OS bytes of the data and recomputes the checksum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const compressed = try serialization_zig.cloudflare_zlib_deflate.gzipLevel9(allocator, "a");
    var checksum: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(compressed, &checksum, .{});
    const fileBytes = try std.mem.concat(allocator, u8, &.{ compressed, &checksum });

    const expectedData = [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03, 0x4b, 0x04, 0x00, 0x43, 0xbe, 0xb7, 0xe8, 0x01, 0x00, 0x00, 0x00 };
    var expectedChecksum: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&expectedData, &expectedChecksum, .{});
    const expected = try std.mem.concat(allocator, u8, &.{ &expectedData, &expectedChecksum });
    try std.testing.expectEqualSlices(u8, expected, try gzip_fixture_os_byte.normaliseSavedFileGzipOsBytes(allocator, fileBytes));
}
