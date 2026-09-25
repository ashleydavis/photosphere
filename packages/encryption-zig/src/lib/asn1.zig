const std = @import("std");

//
// DER encoding and decoding of the RSA key structures that node:crypto imports and exports.
// This file has no TypeScript counterpart: TypeScript uses node:crypto (OpenSSL) for key encoding.
//
// Structures handled:
//   SubjectPublicKeyInfo (SPKI, "PUBLIC KEY" PEM)       = SEQUENCE { AlgorithmIdentifier, BIT STRING { RSAPublicKey } }
//   PrivateKeyInfo (PKCS#8, "PRIVATE KEY" PEM)          = SEQUENCE { INTEGER 0, AlgorithmIdentifier, OCTET STRING { RSAPrivateKey } }
//   RSAPublicKey (PKCS#1, "RSA PUBLIC KEY" PEM)         = SEQUENCE { n, e }
//   RSAPrivateKey (PKCS#1, "RSA PRIVATE KEY" PEM)       = SEQUENCE { 0, n, e, d, p, q, dP, dQ, qInv }
//   AlgorithmIdentifier for rsaEncryption               = SEQUENCE { OID 1.2.840.113549.1.1.1, NULL }
//

//
// The DER tag of an INTEGER.
//
pub const tag_integer: u8 = 0x02;

//
// The DER tag of a BIT STRING.
//
pub const tag_bit_string: u8 = 0x03;

//
// The DER tag of an OCTET STRING.
//
pub const tag_octet_string: u8 = 0x04;

//
// The DER tag of NULL.
//
pub const tag_null: u8 = 0x05;

//
// The DER tag of an OBJECT IDENTIFIER.
//
pub const tag_object_identifier: u8 = 0x06;

//
// The DER tag of a SEQUENCE.
//
pub const tag_sequence: u8 = 0x30;

//
// The encoded contents of the rsaEncryption object identifier (1.2.840.113549.1.1.1).
//
pub const rsa_encryption_oid = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };

//
// Errors raised when DER data cannot be decoded.
//
pub const DecodeError = error{InvalidDer};

//
// The components of an RSA public key, as unsigned big-endian integers without leading zeros.
//
pub const RsaPublicKeyComponents = struct {
    // The modulus n.
    modulus: []const u8,

    // The public exponent e.
    public_exponent: []const u8,
};

//
// The components of an RSA private key (PKCS#1 RSAPrivateKey), as unsigned big-endian integers without leading zeros.
//
pub const RsaPrivateKeyComponents = struct {
    // The modulus n.
    modulus: []const u8,

    // The public exponent e.
    public_exponent: []const u8,

    // The private exponent d.
    private_exponent: []const u8,

    // The first prime p.
    prime1: []const u8,

    // The second prime q.
    prime2: []const u8,

    // d mod (p - 1).
    exponent1: []const u8,

    // d mod (q - 1).
    exponent2: []const u8,

    // q^-1 mod p.
    coefficient: []const u8,
};

//
// Reads consecutive DER elements from a byte string.
//
pub const DerReader = struct {
    // The bytes being decoded.
    bytes: []const u8,

    // The offset of the next element.
    position: usize,

    //
    // Creates a reader over a byte string.
    //
    pub fn init(bytes: []const u8) DerReader {
        return DerReader{ .bytes = bytes, .position = 0 };
    }

    //
    // Returns true when every byte has been read.
    //
    pub fn atEnd(self: *const DerReader) bool {
        return self.position == self.bytes.len;
    }

    //
    // Reads the next element, checks its tag and returns its contents.
    //
    pub fn readElement(self: *DerReader, expected_tag: u8) DecodeError![]const u8 {
        if (self.position + 2 > self.bytes.len) {
            return error.InvalidDer;
        }
        const tag = self.bytes[self.position];
        if (tag != expected_tag) {
            return error.InvalidDer;
        }
        var offset = self.position + 1;
        const first_length_byte = self.bytes[offset];
        offset += 1;
        var length: usize = 0;
        if (first_length_byte < 0x80) {
            length = first_length_byte;
        }
        else {
            const length_byte_count = first_length_byte & 0x7f;
            if (length_byte_count == 0 or length_byte_count > 4 or offset + length_byte_count > self.bytes.len) {
                return error.InvalidDer;
            }
            var length_index: usize = 0;
            while (length_index < length_byte_count) : (length_index += 1) {
                length = (length << 8) | self.bytes[offset + length_index];
            }
            offset += length_byte_count;
        }
        if (offset + length > self.bytes.len) {
            return error.InvalidDer;
        }
        self.position = offset + length;
        return self.bytes[offset .. offset + length];
    }

    //
    // Reads an INTEGER that must be non-negative and returns its big-endian magnitude without leading zeros.
    //
    pub fn readUnsignedInteger(self: *DerReader) DecodeError![]const u8 {
        const contents = try self.readElement(tag_integer);
        if (contents.len == 0 or (contents[0] & 0x80) != 0) {
            return error.InvalidDer;
        }
        var start: usize = 0;
        while (start + 1 < contents.len and contents[start] == 0) {
            start += 1;
        }
        return contents[start..];
    }
};

//
// Appends a DER length to a list.
//
fn appendLength(allocator: std.mem.Allocator, output: *std.ArrayList(u8), length: usize) !void {
    if (length < 0x80) {
        try output.append(allocator, @intCast(length));
        return;
    }
    var length_bytes: [8]u8 = undefined;
    var byte_count: usize = 0;
    var remaining = length;
    while (remaining > 0) {
        length_bytes[7 - byte_count] = @truncate(remaining);
        remaining >>= 8;
        byte_count += 1;
    }
    try output.append(allocator, @intCast(0x80 | byte_count));
    try output.appendSlice(allocator, length_bytes[8 - byte_count ..]);
}

//
// Encodes one DER element from a tag and its contents.
//
pub fn encodeElement(allocator: std.mem.Allocator, tag: u8, contents: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    try output.append(allocator, tag);
    try appendLength(allocator, &output, contents.len);
    try output.appendSlice(allocator, contents);
    return output.toOwnedSlice(allocator);
}

//
// Encodes a DER element whose contents are the concatenation of already encoded parts.
//
pub fn encodeConstructed(allocator: std.mem.Allocator, tag: u8, parts: []const []const u8) ![]u8 {
    const contents = try std.mem.concat(allocator, u8, parts);
    return encodeElement(allocator, tag, contents);
}

//
// Encodes an unsigned big-endian integer as a DER INTEGER (minimal, with a 0x00 prefix when the high bit is set).
//
pub fn encodeUnsignedInteger(allocator: std.mem.Allocator, magnitude: []const u8) ![]u8 {
    var trimmed: []const u8 = &[_]u8{0};
    if (magnitude.len > 0) {
        var start: usize = 0;
        while (start + 1 < magnitude.len and magnitude[start] == 0) {
            start += 1;
        }
        trimmed = magnitude[start..];
    }
    if ((trimmed[0] & 0x80) != 0) {
        const prefixed = try std.mem.concat(allocator, u8, &.{ &[_]u8{0}, trimmed });
        return encodeElement(allocator, tag_integer, prefixed);
    }
    return encodeElement(allocator, tag_integer, trimmed);
}

//
// Encodes the AlgorithmIdentifier for rsaEncryption.
//
fn encodeRsaAlgorithmIdentifier(allocator: std.mem.Allocator) ![]u8 {
    const oid = try encodeElement(allocator, tag_object_identifier, &rsa_encryption_oid);
    const null_element = try encodeElement(allocator, tag_null, &.{});
    return encodeConstructed(allocator, tag_sequence, &.{ oid, null_element });
}

//
// Reads an AlgorithmIdentifier and checks that it is rsaEncryption (with optional NULL parameters).
//
fn readRsaAlgorithmIdentifier(reader: *DerReader) DecodeError!void {
    const algorithm = try reader.readElement(tag_sequence);
    var algorithm_reader = DerReader.init(algorithm);
    const oid = try algorithm_reader.readElement(tag_object_identifier);
    if (!std.mem.eql(u8, oid, &rsa_encryption_oid)) {
        return error.InvalidDer;
    }
    if (!algorithm_reader.atEnd()) {
        const parameters = try algorithm_reader.readElement(tag_null);
        if (parameters.len != 0) {
            return error.InvalidDer;
        }
    }
}

//
// Encodes a PKCS#1 RSAPublicKey.
//
pub fn encodeRsaPublicKey(allocator: std.mem.Allocator, components: RsaPublicKeyComponents) ![]u8 {
    const modulus = try encodeUnsignedInteger(allocator, components.modulus);
    const exponent = try encodeUnsignedInteger(allocator, components.public_exponent);
    return encodeConstructed(allocator, tag_sequence, &.{ modulus, exponent });
}

//
// Decodes a PKCS#1 RSAPublicKey.
//
pub fn decodeRsaPublicKey(der: []const u8) DecodeError!RsaPublicKeyComponents {
    var outer = DerReader.init(der);
    const sequence = try outer.readElement(tag_sequence);
    if (!outer.atEnd()) {
        return error.InvalidDer;
    }
    var reader = DerReader.init(sequence);
    const modulus = try reader.readUnsignedInteger();
    const public_exponent = try reader.readUnsignedInteger();
    if (!reader.atEnd()) {
        return error.InvalidDer;
    }
    return RsaPublicKeyComponents{ .modulus = modulus, .public_exponent = public_exponent };
}

//
// Encodes a SubjectPublicKeyInfo for an RSA public key (what node:crypto exports as type 'spki').
//
pub fn encodeSubjectPublicKeyInfo(allocator: std.mem.Allocator, components: RsaPublicKeyComponents) ![]u8 {
    const algorithm = try encodeRsaAlgorithmIdentifier(allocator);
    const rsa_public_key = try encodeRsaPublicKey(allocator, components);
    const bit_string_contents = try std.mem.concat(allocator, u8, &.{ &[_]u8{0}, rsa_public_key });
    const bit_string = try encodeElement(allocator, tag_bit_string, bit_string_contents);
    return encodeConstructed(allocator, tag_sequence, &.{ algorithm, bit_string });
}

//
// Decodes a SubjectPublicKeyInfo holding an RSA public key.
//
pub fn decodeSubjectPublicKeyInfo(der: []const u8) DecodeError!RsaPublicKeyComponents {
    var outer = DerReader.init(der);
    const sequence = try outer.readElement(tag_sequence);
    if (!outer.atEnd()) {
        return error.InvalidDer;
    }
    var reader = DerReader.init(sequence);
    try readRsaAlgorithmIdentifier(&reader);
    const bit_string = try reader.readElement(tag_bit_string);
    if (!reader.atEnd() or bit_string.len < 1 or bit_string[0] != 0) {
        return error.InvalidDer;
    }
    return decodeRsaPublicKey(bit_string[1..]);
}

//
// Encodes a PKCS#1 RSAPrivateKey.
//
pub fn encodeRsaPrivateKey(allocator: std.mem.Allocator, components: RsaPrivateKeyComponents) ![]u8 {
    const values = [_][]const u8{
        &[_]u8{0},
        components.modulus,
        components.public_exponent,
        components.private_exponent,
        components.prime1,
        components.prime2,
        components.exponent1,
        components.exponent2,
        components.coefficient,
    };
    var parts: [values.len][]const u8 = undefined;
    for (values, 0..) |value, value_index| {
        parts[value_index] = try encodeUnsignedInteger(allocator, value);
    }
    return encodeConstructed(allocator, tag_sequence, &parts);
}

//
// Decodes a PKCS#1 RSAPrivateKey (two-prime keys only, version 0).
//
pub fn decodeRsaPrivateKey(der: []const u8) DecodeError!RsaPrivateKeyComponents {
    var outer = DerReader.init(der);
    const sequence = try outer.readElement(tag_sequence);
    if (!outer.atEnd()) {
        return error.InvalidDer;
    }
    var reader = DerReader.init(sequence);
    const version = try reader.readUnsignedInteger();
    if (version.len != 1 or version[0] != 0) {
        return error.InvalidDer;
    }
    const components = RsaPrivateKeyComponents{
        .modulus = try reader.readUnsignedInteger(),
        .public_exponent = try reader.readUnsignedInteger(),
        .private_exponent = try reader.readUnsignedInteger(),
        .prime1 = try reader.readUnsignedInteger(),
        .prime2 = try reader.readUnsignedInteger(),
        .exponent1 = try reader.readUnsignedInteger(),
        .exponent2 = try reader.readUnsignedInteger(),
        .coefficient = try reader.readUnsignedInteger(),
    };
    if (!reader.atEnd()) {
        return error.InvalidDer;
    }
    return components;
}

//
// Encodes a PKCS#8 PrivateKeyInfo holding an RSA private key (what node:crypto exports as type 'pkcs8').
//
pub fn encodePrivateKeyInfo(allocator: std.mem.Allocator, components: RsaPrivateKeyComponents) ![]u8 {
    const version = try encodeUnsignedInteger(allocator, &[_]u8{0});
    const algorithm = try encodeRsaAlgorithmIdentifier(allocator);
    const rsa_private_key = try encodeRsaPrivateKey(allocator, components);
    const octet_string = try encodeElement(allocator, tag_octet_string, rsa_private_key);
    return encodeConstructed(allocator, tag_sequence, &.{ version, algorithm, octet_string });
}

//
// Decodes a PKCS#8 PrivateKeyInfo holding an RSA private key.
//
pub fn decodePrivateKeyInfo(der: []const u8) DecodeError!RsaPrivateKeyComponents {
    var outer = DerReader.init(der);
    const sequence = try outer.readElement(tag_sequence);
    if (!outer.atEnd()) {
        return error.InvalidDer;
    }
    var reader = DerReader.init(sequence);
    const version = try reader.readUnsignedInteger();
    if (version.len != 1 or version[0] != 0) {
        return error.InvalidDer;
    }
    try readRsaAlgorithmIdentifier(&reader);
    const octet_string = try reader.readElement(tag_octet_string);

    //
    // Optional trailing attributes ([0] IMPLICIT) are ignored.
    //
    return decodeRsaPrivateKey(octet_string);
}
