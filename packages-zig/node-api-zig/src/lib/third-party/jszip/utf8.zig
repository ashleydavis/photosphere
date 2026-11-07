//
// Port of JSZip 3.10.1 lib/utf8.js: only utf8decode, which loading a zip uses to decode file names.
//
// JSZip (c) 2009-2016 Stuart Knightley, David Duponchel, Franz Buchinger, António Afonso, MIT license.
//

const std = @import("std");

//
// Transform a Buffer of UTF-8 bytes into a string.
//
// In Node JSZip decodes with `Buffer.toString("utf-8")`, which follows the WHATWG UTF-8 decoder: every maximal
// subpart of an ill-formed sequence becomes one U+FFFD. The Zig string is the UTF-8 encoding of the decoded text,
// so well-formed input comes back unchanged.
//
pub fn utf8decode(allocator: std.mem.Allocator, buf: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < buf.len) {
        const sequenceLength = wellFormedSequenceLength(buf[index..]);
        if (sequenceLength > 0) {
            try output.appendSlice(allocator, buf[index .. index + sequenceLength]);
            index += sequenceLength;
            continue;
        }
        try output.appendSlice(allocator, "\u{FFFD}");
        index += maximalSubpartLength(buf[index..]);
    }
    return output.items;
}

//
// The length of the well-formed UTF-8 sequence that starts the bytes, or 0 when they do not start with one.
// (No JavaScript counterpart: the WHATWG decoder Node uses.)
//
fn wellFormedSequenceLength(bytes: []const u8) usize {
    const first = bytes[0];
    if (first < 0x80) {
        return 1;
    }
    const length: usize = if (first >= 0xC2 and first <= 0xDF) 2 else if (first >= 0xE0 and first <= 0xEF) 3 else if (first >= 0xF0 and first <= 0xF4) 4 else 0;
    if (length == 0 or bytes.len < length) {
        return 0;
    }
    for (1..length) |position| {
        if (!isContinuationAllowed(first, position, bytes[position])) {
            return 0;
        }
    }
    return length;
}

//
// The length of the maximal subpart of an ill-formed sequence that starts the bytes (at least 1): the lead byte and
// the continuation bytes that could still have continued it. (No JavaScript counterpart.)
//
fn maximalSubpartLength(bytes: []const u8) usize {
    const first = bytes[0];
    const length: usize = if (first >= 0xC2 and first <= 0xDF) 2 else if (first >= 0xE0 and first <= 0xEF) 3 else if (first >= 0xF0 and first <= 0xF4) 4 else 1;
    var consumed: usize = 1;
    while (consumed < length and consumed < bytes.len and isContinuationAllowed(first, consumed, bytes[consumed])) {
        consumed += 1;
    }
    return consumed;
}

//
// Whether a byte may follow as the continuation byte at the given position of a sequence with this lead byte
// (the ranges of the WHATWG UTF-8 decoder). (No JavaScript counterpart.)
//
fn isContinuationAllowed(first: u8, position: usize, byte: u8) bool {
    if (position == 1) {
        const lowerBound: u8 = if (first == 0xE0) 0xA0 else if (first == 0xF0) 0x90 else 0x80;
        const upperBound: u8 = if (first == 0xED) 0x9F else if (first == 0xF4) 0x8F else 0xBF;
        return byte >= lowerBound and byte <= upperBound;
    }
    return byte >= 0x80 and byte <= 0xBF;
}
