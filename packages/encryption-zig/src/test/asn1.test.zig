const std = @import("std");
const encryption = @import("encryption-zig");
const helpers = @import("test-helpers.zig");

const asn1 = encryption.asn1;
const pem = encryption.pem;

test "encodeUnsignedInteger adds a zero byte when the high bit is set and strips leading zeros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x01, 0x00 }, try asn1.encodeUnsignedInteger(allocator, &.{0}));
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x01, 0x7f }, try asn1.encodeUnsignedInteger(allocator, &.{ 0, 0, 0x7f }));
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x02, 0x00, 0x80 }, try asn1.encodeUnsignedInteger(allocator, &.{0x80}));
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x03, 0x01, 0x00, 0x01 }, try asn1.encodeUnsignedInteger(allocator, &.{ 0x01, 0x00, 0x01 }));
}

test "encodeElement uses long form lengths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const short = try asn1.encodeElement(allocator, asn1.tag_octet_string, &([_]u8{0xaa} ** 127));
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x7f }, short[0..2]);
    const medium = try asn1.encodeElement(allocator, asn1.tag_octet_string, &([_]u8{0xaa} ** 200));
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x81, 0xc8 }, medium[0..3]);
    const long = try asn1.encodeElement(allocator, asn1.tag_octet_string, &([_]u8{0xaa} ** 600));
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x82, 0x02, 0x58 }, long[0..4]);

    var reader = asn1.DerReader.init(long);
    const contents = try reader.readElement(asn1.tag_octet_string);
    try std.testing.expectEqual(@as(usize, 600), contents.len);
    try std.testing.expect(reader.atEnd());
}

test "decodeSubjectPublicKeyInfo and encodeSubjectPublicKeyInfo round-trip the TypeScript public key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const block = try pem.decode(allocator, try helpers.readFixture(allocator, "ts-public.pem"));
    const components = try asn1.decodeSubjectPublicKeyInfo(block.der);
    try std.testing.expectEqual(@as(usize, 512), components.modulus.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x01 }, components.public_exponent);
    try std.testing.expectEqualSlices(u8, block.der, try asn1.encodeSubjectPublicKeyInfo(allocator, components));
}

test "decodePrivateKeyInfo and encodePrivateKeyInfo round-trip the TypeScript private key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const block = try pem.decode(allocator, try helpers.readFixture(allocator, "ts-private.pem"));
    const components = try asn1.decodePrivateKeyInfo(block.der);
    try std.testing.expectEqual(@as(usize, 512), components.modulus.len);
    try std.testing.expectEqual(@as(usize, 256), components.prime1.len);
    try std.testing.expectEqualSlices(u8, block.der, try asn1.encodePrivateKeyInfo(allocator, components));

    //
    // The PKCS#1 structure inside also round-trips.
    //
    const rsa_private_key = try asn1.encodeRsaPrivateKey(allocator, components);
    const decoded = try asn1.decodeRsaPrivateKey(rsa_private_key);
    try std.testing.expectEqualSlices(u8, components.coefficient, decoded.coefficient);
}

test "decoders reject malformed data" {
    try std.testing.expectError(error.InvalidDer, asn1.decodeSubjectPublicKeyInfo(&.{ 0x30, 0x05, 0x00 }));
    try std.testing.expectError(error.InvalidDer, asn1.decodePrivateKeyInfo(&.{ 0x04, 0x00 }));
    try std.testing.expectError(error.InvalidDer, asn1.decodeRsaPublicKey(&.{ 0x30, 0x03, 0x02, 0x01, 0x80 }));
    try std.testing.expectError(error.InvalidDer, asn1.decodeRsaPrivateKey(&.{}));
}
