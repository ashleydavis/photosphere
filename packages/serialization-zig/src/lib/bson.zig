const std = @import("std");
const utils = @import("utils-zig");
const errors = utils.errors;

//
// BSON encoding and decoding. This file has no TypeScript counterpart: the TypeScript code calls the npm `bson`
// library (`serialize(obj)` in `BinarySerializer.writeBSON` and `deserialize(buffer)` in `BinaryDeserializer.readBSON`,
// both with default options). This port reproduces the JavaScript-side semantics of that library as used by this repo,
// so that re-serializing a deserialized document gives the same bytes as TypeScript does.
//
// How each BSON type maps (wire type -> BsonValue when decoding, BsonValue -> wire type when encoding):
//
// | BSON wire type        | Decoded (npm bson, promoteValues/promoteLongs = true) | BsonValue   | Encoded as                   |
// |-----------------------|-------------------------------------------------------|-------------|------------------------------|
// | 0x01 double           | JS number                                             | .number     | see .number below            |
// | 0x10 int32            | JS number                                             | .number     | see .number below            |
// | 0x12 int64 in +-2^53  | JS number (promoteLongs)                              | .number     | see .number below            |
// | 0x12 int64 otherwise  | Long                                                  | .int64      | 0x12 int64                   |
// | 0x02 string           | string (UTF-8 validated)                              | .string     | 0x02 string                  |
// | 0x03 document         | plain object                                          | .document   | 0x03 document                |
// | 0x04 array            | array                                                 | .array      | 0x04 array                   |
// | 0x08 boolean          | boolean                                               | .boolean    | 0x08 boolean                 |
// | 0x0A null             | null                                                  | .null       | 0x0A null                    |
// | 0x06 undefined        | undefined                                             | .undefined  | omitted (see below)          |
// | 0x09 UTC datetime     | Date (milliseconds since the epoch)                   | .date       | 0x09 UTC datetime            |
// | 0x05 binary           | Binary (UUID when subtype 4 and 16 bytes)             | .binary     | 0x05 binary, same subtype    |
// | 0x07 ObjectId         | ObjectId                                              | .objectId   | 0x07 ObjectId                |
// |                       | Int32 wrapper (never produced by deserialize)         | .int32      | 0x10 int32                   |
// |                       | Double wrapper (never produced by deserialize)        | .double     | 0x01 double                  |
//
// A `.number` is a JS number. npm bson encodes it as int32 when it is a safe integer within the int32 range and not -0,
// otherwise as a double. A JS Buffer encodes as binary subtype 0 (use `.binary` with subType 0), a JS bigint as int64
// (use `.int64`). Other BSON types (regex, code, timestamp, decimal128, min/max key, ...) are not used by this app and are
// rejected when decoding with npm bson's "unknown BSON type" message.
//
// `serialize` uses npm bson's default ignoreUndefined = true: a document field whose value is undefined is left out,
// while an undefined array element is written as null.
//
// Document key order follows JavaScript object property order: keys that are array indexes ("0", "1", "42", but not
// "01") come first in ascending numeric order, all other keys follow in insertion order. `BsonDocument.put` keeps this
// order, so a decoded document re-encodes exactly like TypeScript re-encodes the object it deserialized.
//
// Decoded strings and binary data are copied into the allocator (they do not reference the input buffer).
//

//
// BSON element type codes.
//
const bson_type_double: u8 = 0x01;
const bson_type_string: u8 = 0x02;
const bson_type_document: u8 = 0x03;
const bson_type_array: u8 = 0x04;
const bson_type_binary: u8 = 0x05;
const bson_type_undefined: u8 = 0x06;
const bson_type_object_id: u8 = 0x07;
const bson_type_boolean: u8 = 0x08;
const bson_type_date: u8 = 0x09;
const bson_type_null: u8 = 0x0A;
const bson_type_int32: u8 = 0x10;
const bson_type_int64: u8 = 0x12;

//
// The deprecated binary subtype that stores an extra int32 length before the data.
//
const binary_subtype_byte_array: u8 = 0x02;

//
// The largest integer a JS number holds exactly (Number.MAX_SAFE_INTEGER + 1, npm bson's JS_INT_MAX).
//
const js_int_max: i64 = 9007199254740992;

//
// Errors produced by BSON encoding and decoding (messages are recorded like TypeScript's BSONError).
//
pub const BsonError = std.mem.Allocator.Error || errors.ThrownError;

//
// Binary data with its BSON subtype (npm bson `Binary`; subtype 0 is a JS Buffer, subtype 4 is a UUID).
//
pub const BsonBinary = struct {
    // The BSON binary subtype.
    subType: u8,

    // The binary data.
    data: []const u8,
};

//
// A dynamic BSON value (the JavaScript value npm bson produces or accepts). See the table at the top of this file.
//
pub const BsonValue = union(enum) {
    // A JS number (decoded from double, int32 and promotable int64).
    number: f64,

    // An explicit int32 (npm bson `Int32`).
    int32: i32,

    // A 64-bit integer that is not promoted to a JS number (npm bson `Long`, or a JS bigint when encoding).
    int64: i64,

    // An explicit double (npm bson `Double`).
    double: f64,

    // A UTF-8 string.
    string: []const u8,

    // An embedded document (JS plain object).
    document: BsonDocument,

    // An array.
    array: []BsonValue,

    // A boolean.
    boolean: bool,

    // JS null.
    null,

    // JS undefined (left out of documents and written as null in arrays, like npm bson's default ignoreUndefined = true).
    undefined,

    // A JS Date as milliseconds since the Unix epoch (UTC).
    date: i64,

    // Binary data with its subtype.
    binary: BsonBinary,

    // A 12-byte ObjectId.
    objectId: [12]u8,

    //
    // Deep equality of two values (JS `toEqual` semantics for the types above; numbers compare with ==, so NaN != NaN).
    //
    pub fn eql(self: BsonValue, other: BsonValue) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) {
            return false;
        }
        switch (self) {
            .number => |value| {
                return value == other.number;
            },
            .int32 => |value| {
                return value == other.int32;
            },
            .int64 => |value| {
                return value == other.int64;
            },
            .double => |value| {
                return value == other.double;
            },
            .string => |value| {
                return std.mem.eql(u8, value, other.string);
            },
            .document => |value| {
                return value.eql(other.document);
            },
            .array => |value| {
                if (value.len != other.array.len) {
                    return false;
                }
                for (value, other.array) |element, other_element| {
                    if (!element.eql(other_element)) {
                        return false;
                    }
                }
                return true;
            },
            .boolean => |value| {
                return value == other.boolean;
            },
            .null, .undefined => {
                return true;
            },
            .date => |value| {
                return value == other.date;
            },
            .binary => |value| {
                return value.subType == other.binary.subType and std.mem.eql(u8, value.data, other.binary.data);
            },
            .objectId => |value| {
                return std.mem.eql(u8, &value, &other.objectId);
            },
        }
    }
};

//
// One key/value pair of a document.
//
pub const BsonField = struct {
    // The field name.
    key: []const u8,

    // The field value.
    value: BsonValue,
};

//
// A BSON document: an ordered list of key/value pairs (a JS plain object).
//
pub const BsonDocument = struct {
    // The fields in JS property order.
    fields: std.ArrayList(BsonField) = .empty,

    //
    // An empty document.
    //
    pub const empty: BsonDocument = .{};

    //
    // Creates a document by putting the given fields in order (like a JS object literal).
    //
    pub fn fromFields(allocator: std.mem.Allocator, fields: []const BsonField) std.mem.Allocator.Error!BsonDocument {
        var document: BsonDocument = .empty;
        for (fields) |field| {
            try document.put(allocator, field.key, field.value);
        }
        return document;
    }

    //
    // Gets the value of a field (null when the field does not exist).
    //
    pub fn get(self: BsonDocument, key: []const u8) ?BsonValue {
        for (self.fields.items) |field| {
            if (std.mem.eql(u8, field.key, key)) {
                return field.value;
            }
        }
        return null;
    }

    //
    // Gets a pointer to the value of a field (null when the field does not exist).
    //
    pub fn getPtr(self: *BsonDocument, key: []const u8) ?*BsonValue {
        for (self.fields.items) |*field| {
            if (std.mem.eql(u8, field.key, key)) {
                return &field.value;
            }
        }
        return null;
    }

    //
    // Sets a field like a JS property assignment (`object[key] = value`): an existing key keeps its position,
    // a new array index key is placed among the other index keys in ascending order, any other new key is appended.
    // The key is not copied.
    //
    pub fn put(self: *BsonDocument, allocator: std.mem.Allocator, key: []const u8, value: BsonValue) std.mem.Allocator.Error!void {
        if (self.getPtr(key)) |existing| {
            existing.* = value;
            return;
        }
        const new_field: BsonField = .{ .key = key, .value = value };
        const new_index = parseArrayIndex(key) orelse {
            try self.fields.append(allocator, new_field);
            return;
        };
        var position: usize = 0;
        while (position < self.fields.items.len) : (position += 1) {
            const existing_index = parseArrayIndex(self.fields.items[position].key) orelse {
                break;
            };
            if (existing_index > new_index) {
                break;
            }
        }
        try self.fields.insert(allocator, position, new_field);
    }

    //
    // Removes a field (JS `delete object[key]`). Returns true when the field existed.
    //
    pub fn remove(self: *BsonDocument, key: []const u8) bool {
        for (self.fields.items, 0..) |field, index| {
            if (std.mem.eql(u8, field.key, key)) {
                _ = self.fields.orderedRemove(index);
                return true;
            }
        }
        return false;
    }

    //
    // The number of fields.
    //
    pub fn count(self: BsonDocument) usize {
        return self.fields.items.len;
    }

    //
    // Deep equality of two documents (same keys in the same order with equal values).
    //
    pub fn eql(self: BsonDocument, other: BsonDocument) bool {
        if (self.fields.items.len != other.fields.items.len) {
            return false;
        }
        for (self.fields.items, other.fields.items) |field, other_field| {
            if (!std.mem.eql(u8, field.key, other_field.key)) {
                return false;
            }
            if (!field.value.eql(other_field.value)) {
                return false;
            }
        }
        return true;
    }
};

//
// Returns the numeric value of a key when it is a JS array index (canonical decimal below 2^32 - 1), otherwise null.
// JS objects order such keys before all other keys.
//
fn parseArrayIndex(key: []const u8) ?u32 {
    if (key.len == 0 or key.len > 10) {
        return null;
    }
    if (key.len > 1 and key[0] == '0') {
        return null;
    }
    var value: u64 = 0;
    for (key) |character| {
        if (character < '0' or character > '9') {
            return null;
        }
        value = value * 10 + (character - '0');
    }
    if (value >= 0xFFFFFFFF) {
        return null;
    }
    return @intCast(value);
}

//
// Serializes a document to BSON bytes (npm bson `serialize(obj)` with default options).
//
pub fn serialize(allocator: std.mem.Allocator, document: BsonDocument) BsonError![]u8 {
    var output: std.ArrayList(u8) = .empty;
    try serializeDocument(allocator, &output, document);
    return output.toOwnedSlice(allocator);
}

//
// Appends a little-endian integer to the output.
//
fn appendInt(allocator: std.mem.Allocator, output: *std.ArrayList(u8), comptime IntT: type, value: IntT) std.mem.Allocator.Error!void {
    var bytes: [@sizeOf(IntT)]u8 = undefined;
    std.mem.writeInt(IntT, &bytes, value, .little);
    try output.appendSlice(allocator, &bytes);
}

//
// Appends a document (int32 size, elements, terminating zero) to the output.
//
fn serializeDocument(allocator: std.mem.Allocator, output: *std.ArrayList(u8), document: BsonDocument) BsonError!void {
    const start = output.items.len;
    try appendInt(allocator, output, i32, 0);
    for (document.fields.items) |field| {
        if (field.value == .undefined) {
            // ignoreUndefined: undefined document fields are not written.
            continue;
        }
        try serializeElement(allocator, output, field.key, field.value);
    }
    try output.append(allocator, 0);
    patchSize(output, start);
}

//
// Appends an array (a document keyed "0", "1", ...) to the output.
//
fn serializeArray(allocator: std.mem.Allocator, output: *std.ArrayList(u8), elements: []const BsonValue) BsonError!void {
    const start = output.items.len;
    try appendInt(allocator, output, i32, 0);
    for (elements, 0..) |element, index| {
        var key_buffer: [20]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buffer, "{d}", .{index}) catch unreachable;
        try serializeElement(allocator, output, key, element);
    }
    try output.append(allocator, 0);
    patchSize(output, start);
}

//
// Writes the final size of a document or array that starts at `start`.
//
fn patchSize(output: *std.ArrayList(u8), start: usize) void {
    const size: i32 = @intCast(output.items.len - start);
    std.mem.writeInt(i32, output.items[start..][0..4], size, .little);
}

//
// Appends the element type and the key (a C string) to the output.
//
fn serializeElementHeader(allocator: std.mem.Allocator, output: *std.ArrayList(u8), element_type: u8, key: []const u8) BsonError!void {
    if (std.mem.indexOfScalar(u8, key, 0) != null) {
        return errors.throwError("key {s} must not contain null bytes", .{key});
    }
    try output.append(allocator, element_type);
    try output.appendSlice(allocator, key);
    try output.append(allocator, 0);
}

//
// Returns true when npm bson encodes a JS number as int32 (a safe integer in the int32 range that is not -0).
//
fn isInt32Number(value: f64) bool {
    if (!std.math.isFinite(value)) {
        return false;
    }
    if (value != @trunc(value)) {
        return false;
    }
    if (value == 0 and std.math.signbit(value)) {
        return false;
    }
    return value >= -2147483648.0 and value <= 2147483647.0;
}

//
// Appends one element (type, key and value) to the output.
//
fn serializeElement(allocator: std.mem.Allocator, output: *std.ArrayList(u8), key: []const u8, value: BsonValue) BsonError!void {
    switch (value) {
        .number => |number| {
            if (isInt32Number(number)) {
                try serializeElementHeader(allocator, output, bson_type_int32, key);
                try appendInt(allocator, output, i32, @intFromFloat(number));
            }
            else {
                try serializeElementHeader(allocator, output, bson_type_double, key);
                try appendInt(allocator, output, u64, @bitCast(number));
            }
        },
        .int32 => |number| {
            try serializeElementHeader(allocator, output, bson_type_int32, key);
            try appendInt(allocator, output, i32, number);
        },
        .int64 => |number| {
            try serializeElementHeader(allocator, output, bson_type_int64, key);
            try appendInt(allocator, output, i64, number);
        },
        .double => |number| {
            try serializeElementHeader(allocator, output, bson_type_double, key);
            try appendInt(allocator, output, u64, @bitCast(number));
        },
        .string => |string| {
            try serializeElementHeader(allocator, output, bson_type_string, key);
            try appendInt(allocator, output, i32, @intCast(string.len + 1));
            try output.appendSlice(allocator, string);
            try output.append(allocator, 0);
        },
        .document => |document| {
            try serializeElementHeader(allocator, output, bson_type_document, key);
            try serializeDocument(allocator, output, document);
        },
        .array => |elements| {
            try serializeElementHeader(allocator, output, bson_type_array, key);
            try serializeArray(allocator, output, elements);
        },
        .boolean => |boolean| {
            try serializeElementHeader(allocator, output, bson_type_boolean, key);
            try output.append(allocator, if (boolean) 1 else 0);
        },
        .null, .undefined => {
            try serializeElementHeader(allocator, output, bson_type_null, key);
        },
        .date => |milliseconds| {
            try serializeElementHeader(allocator, output, bson_type_date, key);
            try appendInt(allocator, output, i64, milliseconds);
        },
        .binary => |binary| {
            try serializeElementHeader(allocator, output, bson_type_binary, key);
            if (binary.subType == binary_subtype_byte_array) {
                try appendInt(allocator, output, i32, @intCast(binary.data.len + 4));
                try output.append(allocator, binary.subType);
                try appendInt(allocator, output, i32, @intCast(binary.data.len));
            }
            else {
                try appendInt(allocator, output, i32, @intCast(binary.data.len));
                try output.append(allocator, binary.subType);
            }
            try output.appendSlice(allocator, binary.data);
        },
        .objectId => |object_id| {
            try serializeElementHeader(allocator, output, bson_type_object_id, key);
            try output.appendSlice(allocator, &object_id);
        },
    }
}

//
// Deserializes BSON bytes into a document (npm bson `deserialize(buffer)` with default options).
// Like npm bson, the buffer length must equal the document size.
//
pub fn deserialize(allocator: std.mem.Allocator, buffer: []const u8) BsonError!BsonDocument {
    if (buffer.len < 4) {
        return errors.throwError("bson size must be >= 5, is {d}", .{buffer.len});
    }
    const size = std.mem.readInt(i32, buffer[0..4], .little);
    if (size < 5) {
        return errors.throwError("bson size must be >= 5, is {d}", .{size});
    }
    if (buffer.len != @as(usize, @intCast(size))) {
        return errors.throwError("buffer length {d} must === bson size {d}", .{ buffer.len, size });
    }
    if (buffer[buffer.len - 1] != 0) {
        return errors.throwError("One object, sized correctly, with a spot for an EOO, but the EOO isn't 0x00", .{});
    }
    var reader: Reader = .{ .buffer = buffer, .index = 0 };
    return reader.readDocument(allocator);
}

//
// Reads BSON elements from a buffer, tracking the current position.
//
const Reader = struct {
    // The complete BSON buffer.
    buffer: []const u8,

    // The current read position.
    index: usize,

    //
    // Reads a little-endian integer, checking that it is inside the buffer.
    //
    fn readInt(self: *Reader, comptime IntT: type) BsonError!IntT {
        if (self.index + @sizeOf(IntT) > self.buffer.len) {
            return errors.throwError("corrupt bson message", .{});
        }
        const value = std.mem.readInt(IntT, self.buffer[self.index..][0..@sizeOf(IntT)], .little);
        self.index += @sizeOf(IntT);
        return value;
    }

    //
    // Reads a byte, checking that it is inside the buffer.
    //
    fn readByte(self: *Reader) BsonError!u8 {
        if (self.index >= self.buffer.len) {
            return errors.throwError("corrupt bson message", .{});
        }
        const value = self.buffer[self.index];
        self.index += 1;
        return value;
    }

    //
    // Reads a number of bytes, copying them into the allocator.
    //
    fn readCopy(self: *Reader, allocator: std.mem.Allocator, length: usize) BsonError![]u8 {
        if (length > self.buffer.len - self.index) {
            return errors.throwError("corrupt bson message", .{});
        }
        const copy = try allocator.dupe(u8, self.buffer[self.index .. self.index + length]);
        self.index += length;
        return copy;
    }

    //
    // Reads the size of an embedded document or array, validating it like npm bson.
    //
    fn readObjectSize(self: *Reader) BsonError!usize {
        if (self.buffer.len < 5) {
            return errors.throwError("corrupt bson message < 5 bytes long", .{});
        }
        const size = try self.readInt(i32);
        if (size < 5 or @as(usize, @intCast(size)) > self.buffer.len) {
            return errors.throwError("corrupt bson message", .{});
        }
        return @intCast(size);
    }

    //
    // Reads the element type and key of the next element. Returns null at the end of the document.
    //
    fn readElementHeader(self: *Reader, element_type: *u8) BsonError!?[]const u8 {
        element_type.* = try self.readByte();
        if (element_type.* == 0) {
            return null;
        }
        const key_end = std.mem.indexOfScalarPos(u8, self.buffer, self.index, 0) orelse {
            return errors.throwError("Bad BSON Document: illegal CString", .{});
        };
        const key = self.buffer[self.index..key_end];
        self.index = key_end + 1;
        return key;
    }

    //
    // Reads an embedded document.
    //
    fn readDocument(self: *Reader, allocator: std.mem.Allocator) BsonError!BsonDocument {
        const start = self.index;
        const size = try self.readObjectSize();
        var document: BsonDocument = .empty;
        while (true) {
            var element_type: u8 = 0;
            const key = try self.readElementHeader(&element_type) orelse {
                break;
            };
            const owned_key = try allocator.dupe(u8, key);
            const value = try self.readValue(allocator, element_type, key);
            try document.put(allocator, owned_key, value);
        }
        if (size != self.index - start) {
            return errors.throwError("corrupt object bson", .{});
        }
        return document;
    }

    //
    // Reads an array (element keys are ignored, elements are taken in order like npm bson).
    //
    fn readArray(self: *Reader, allocator: std.mem.Allocator) BsonError![]BsonValue {
        const start = self.index;
        const size = try self.readObjectSize();
        var elements: std.ArrayList(BsonValue) = .empty;
        while (true) {
            var element_type: u8 = 0;
            const key = try self.readElementHeader(&element_type) orelse {
                break;
            };
            try elements.append(allocator, try self.readValue(allocator, element_type, key));
        }
        if (size != self.index - start) {
            return errors.throwError("corrupt array bson", .{});
        }
        return elements.toOwnedSlice(allocator);
    }

    //
    // Reads the value of an element of the given type.
    //
    fn readValue(self: *Reader, allocator: std.mem.Allocator, element_type: u8, key: []const u8) BsonError!BsonValue {
        switch (element_type) {
            bson_type_string => {
                const string_size = try self.readInt(i32);
                if (string_size <= 0 or @as(usize, @intCast(string_size)) > self.buffer.len - self.index or self.buffer[self.index + @as(usize, @intCast(string_size)) - 1] != 0) {
                    return errors.throwError("bad string length in bson", .{});
                }
                const string = try self.readCopy(allocator, @as(usize, @intCast(string_size)) - 1);
                self.index += 1;
                if (!std.unicode.utf8ValidateSlice(string)) {
                    return errors.throwError("Invalid UTF-8 string in BSON document", .{});
                }
                return .{ .string = string };
            },
            bson_type_object_id => {
                const bytes = try self.readCopy(allocator, 12);
                return .{ .objectId = bytes[0..12].* };
            },
            bson_type_int32 => {
                return .{ .number = @floatFromInt(try self.readInt(i32)) };
            },
            bson_type_double => {
                return .{ .number = @bitCast(try self.readInt(u64)) };
            },
            bson_type_date => {
                return .{ .date = try self.readInt(i64) };
            },
            bson_type_boolean => {
                const byte = try self.readByte();
                if (byte != 0 and byte != 1) {
                    return errors.throwError("illegal boolean type value", .{});
                }
                return .{ .boolean = byte == 1 };
            },
            bson_type_document => {
                return .{ .document = try self.readDocument(allocator) };
            },
            bson_type_array => {
                const elements = try self.readArray(allocator);
                if (self.buffer[self.index - 1] != 0) {
                    return errors.throwError("invalid array terminator byte", .{});
                }
                return .{ .array = elements };
            },
            bson_type_undefined => {
                return .undefined;
            },
            bson_type_null => {
                return .null;
            },
            bson_type_int64 => {
                const number = try self.readInt(i64);
                if (number <= js_int_max and number >= -js_int_max) {
                    return .{ .number = @floatFromInt(number) };
                }
                return .{ .int64 = number };
            },
            bson_type_binary => {
                var binary_size = try self.readInt(i32);
                const total_binary_size = binary_size;
                const sub_type = try self.readByte();
                if (binary_size < 0) {
                    return errors.throwError("Negative binary type element size found", .{});
                }
                if (@as(usize, @intCast(binary_size)) > self.buffer.len) {
                    return errors.throwError("Binary type size larger than document size", .{});
                }
                if (sub_type == binary_subtype_byte_array) {
                    binary_size = try self.readInt(i32);
                    if (binary_size < 0) {
                        return errors.throwError("Negative binary type element size found for subtype 0x02", .{});
                    }
                    if (binary_size > total_binary_size - 4) {
                        return errors.throwError("Binary type with subtype 0x02 contains too long binary size", .{});
                    }
                    if (binary_size < total_binary_size - 4) {
                        return errors.throwError("Binary type with subtype 0x02 contains too short binary size", .{});
                    }
                }
                const data = try self.readCopy(allocator, @intCast(binary_size));
                return .{ .binary = .{ .subType = sub_type, .data = data } };
            },
            else => {
                return errors.throwError("Detected unknown BSON type {x} for fieldname \"{s}\"", .{ element_type, key });
            },
        }
    }
};
