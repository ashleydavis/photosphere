const std = @import("std");

//
// PEM armor (RFC 7468) as written and read by node:crypto.
// This file has no TypeScript counterpart: TypeScript uses node:crypto (OpenSSL) for PEM.
//
// Node writes "-----BEGIN <label>-----\n", the base64 of the DER in lines of 64 characters, then
// "-----END <label>-----\n".
//

//
// The number of base64 characters per line in PEM output.
//
const line_length = 64;

//
// Errors raised when PEM text cannot be decoded.
//
pub const DecodeError = error{InvalidPem};

//
// A decoded PEM block.
//
pub const PemBlock = struct {
    // The label between "BEGIN " and "-----" (e.g. "PUBLIC KEY").
    label: []const u8,

    // The decoded DER bytes.
    der: []u8,
};

//
// Encodes DER bytes as PEM text with the given label, exactly like node:crypto's KeyObject.export.
//
pub fn encode(allocator: std.mem.Allocator, label: []const u8, der: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const base64_text = try allocator.alloc(u8, encoder.calcSize(der.len));
    _ = encoder.encode(base64_text, der);

    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(allocator, "-----BEGIN ");
    try output.appendSlice(allocator, label);
    try output.appendSlice(allocator, "-----\n");
    var offset: usize = 0;
    while (offset < base64_text.len) {
        const end = @min(offset + line_length, base64_text.len);
        try output.appendSlice(allocator, base64_text[offset..end]);
        try output.append(allocator, '\n');
        offset = end;
    }
    try output.appendSlice(allocator, "-----END ");
    try output.appendSlice(allocator, label);
    try output.appendSlice(allocator, "-----\n");
    return output.toOwnedSlice(allocator);
}

//
// Decodes the first PEM block in a text. Whitespace (including CRLF line endings) inside the base64 is ignored.
//
pub fn decode(allocator: std.mem.Allocator, text: []const u8) !PemBlock {
    const begin_marker = "-----BEGIN ";
    const dashes = "-----";
    const begin_index = std.mem.indexOf(u8, text, begin_marker) orelse {
        return error.InvalidPem;
    };
    const label_start = begin_index + begin_marker.len;
    const label_end = std.mem.indexOfPos(u8, text, label_start, dashes) orelse {
        return error.InvalidPem;
    };
    const label = text[label_start..label_end];
    const body_start = label_end + dashes.len;
    const end_marker = try std.mem.concat(allocator, u8, &.{ "-----END ", label, dashes });
    const body_end = std.mem.indexOfPos(u8, text, body_start, end_marker) orelse {
        return error.InvalidPem;
    };

    const body = text[body_start..body_end];
    var compact: std.ArrayList(u8) = .empty;
    for (body) |character| {
        if (!std.ascii.isWhitespace(character)) {
            try compact.append(allocator, character);
        }
    }
    const decoder = std.base64.standard.Decoder;
    const der_length = decoder.calcSizeForSlice(compact.items) catch {
        return error.InvalidPem;
    };
    const der = try allocator.alloc(u8, der_length);
    decoder.decode(der, compact.items) catch {
        return error.InvalidPem;
    };
    return PemBlock{ .label = label, .der = der };
}
