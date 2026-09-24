//
// Binary serialization and deserialization with versioning support.
//

const std = @import("std");
const utils = @import("utils-zig");
const bson = @import("bson.zig");
const cloudflare_zlib_deflate = @import("cloudflare-zlib-deflate.zig");
const errors = utils.errors;
const retry = utils.retry.retry;
const flate = std.compress.flate;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// Errors raised while writing serialized data (allocation failures and thrown errors, for example from BSON encoding).
//
pub const SerializerError = std.mem.Allocator.Error || errors.ThrownError;

//
// Errors raised while reading serialized data (allocation failures and thrown errors, for example out of bounds reads).
//
pub const DeserializerError = std.mem.Allocator.Error || errors.ThrownError;

//
// Interface for writing binary data during serialization
//
pub const ISerializer = struct {
    // The implementation (a *BinarySerializer or *CompressedBinarySerializer).
    ptr: *anyopaque,

    // The implementation's methods.
    vtable: *const VTable,

    //
    // The methods an ISerializer implementation provides (same meaning as the forwarding methods below).
    //
    pub const VTable = struct {
        // See ISerializer.writeUInt32.
        writeUInt32: *const fn (ptr: *anyopaque, value: u32) SerializerError!void,

        // See ISerializer.writeInt32.
        writeInt32: *const fn (ptr: *anyopaque, value: i32) SerializerError!void,

        // See ISerializer.writeUInt64.
        writeUInt64: *const fn (ptr: *anyopaque, value: u64) SerializerError!void,

        // See ISerializer.writeInt64.
        writeInt64: *const fn (ptr: *anyopaque, value: i64) SerializerError!void,

        // See ISerializer.writeFloat.
        writeFloat: *const fn (ptr: *anyopaque, value: f32) SerializerError!void,

        // See ISerializer.writeDouble.
        writeDouble: *const fn (ptr: *anyopaque, value: f64) SerializerError!void,

        // See ISerializer.writeBoolean.
        writeBoolean: *const fn (ptr: *anyopaque, value: bool) SerializerError!void,

        // See ISerializer.writeUInt8.
        writeUInt8: *const fn (ptr: *anyopaque, value: u8) SerializerError!void,

        // See ISerializer.writeString.
        writeString: *const fn (ptr: *anyopaque, value: []const u8) SerializerError!void,

        // See ISerializer.writeBuffer.
        writeBuffer: *const fn (ptr: *anyopaque, buffer: []const u8) SerializerError!void,

        // See ISerializer.writeBytes.
        writeBytes: *const fn (ptr: *anyopaque, buffer: []const u8) SerializerError!void,

        // See ISerializer.writeBSON.
        writeBSON: *const fn (ptr: *anyopaque, obj: bson.BsonDocument) SerializerError!void,
    };

    //
    // Write a 32-bit unsigned integer (little-endian)
    //
    pub fn writeUInt32(self: ISerializer, value: u32) SerializerError!void {
        return self.vtable.writeUInt32(self.ptr, value);
    }

    //
    // Write a 32-bit signed integer (little-endian)
    //
    pub fn writeInt32(self: ISerializer, value: i32) SerializerError!void {
        return self.vtable.writeInt32(self.ptr, value);
    }

    //
    // Write a 64-bit unsigned integer (little-endian)
    //
    pub fn writeUInt64(self: ISerializer, value: u64) SerializerError!void {
        return self.vtable.writeUInt64(self.ptr, value);
    }

    //
    // Write a 64-bit signed integer (little-endian)
    //
    pub fn writeInt64(self: ISerializer, value: i64) SerializerError!void {
        return self.vtable.writeInt64(self.ptr, value);
    }

    //
    // Write a 32-bit float (little-endian)
    //
    pub fn writeFloat(self: ISerializer, value: f32) SerializerError!void {
        return self.vtable.writeFloat(self.ptr, value);
    }

    //
    // Write a 64-bit double (little-endian)
    //
    pub fn writeDouble(self: ISerializer, value: f64) SerializerError!void {
        return self.vtable.writeDouble(self.ptr, value);
    }

    //
    // Write a boolean as a single byte (1 for true, 0 for false)
    //
    pub fn writeBoolean(self: ISerializer, value: bool) SerializerError!void {
        return self.vtable.writeBoolean(self.ptr, value);
    }

    //
    // Write an 8-bit unsigned integer
    //
    pub fn writeUInt8(self: ISerializer, value: u8) SerializerError!void {
        return self.vtable.writeUInt8(self.ptr, value);
    }

    //
    // Write a UTF-8 string (prefixed with 32-bit length)
    //
    pub fn writeString(self: ISerializer, value: []const u8) SerializerError!void {
        return self.vtable.writeString(self.ptr, value);
    }

    //
    // Write raw buffer data (prefixed with 32-bit length)
    //
    pub fn writeBuffer(self: ISerializer, buffer: []const u8) SerializerError!void {
        return self.vtable.writeBuffer(self.ptr, buffer);
    }

    //
    // Write raw bytes without length prefix
    //
    pub fn writeBytes(self: ISerializer, buffer: []const u8) SerializerError!void {
        return self.vtable.writeBytes(self.ptr, buffer);
    }

    //
    // Write BSON data (serializes object to BSON and writes with 32-bit length prefix)
    //
    pub fn writeBSON(self: ISerializer, obj: bson.BsonDocument) SerializerError!void {
        return self.vtable.writeBSON(self.ptr, obj);
    }
};

//
// Interface for reading binary data during deserialization
//
pub const IDeserializer = struct {
    // The implementation (a *BinaryDeserializer or *CompressedBinaryDeserializer).
    ptr: *anyopaque,

    // The implementation's methods.
    vtable: *const VTable,

    //
    // The methods an IDeserializer implementation provides (same meaning as the forwarding methods below).
    //
    pub const VTable = struct {
        // See IDeserializer.readUInt32.
        readUInt32: *const fn (ptr: *anyopaque) DeserializerError!u32,

        // See IDeserializer.readInt32.
        readInt32: *const fn (ptr: *anyopaque) DeserializerError!i32,

        // See IDeserializer.readUInt64.
        readUInt64: *const fn (ptr: *anyopaque) DeserializerError!u64,

        // See IDeserializer.readInt64.
        readInt64: *const fn (ptr: *anyopaque) DeserializerError!i64,

        // See IDeserializer.readFloat.
        readFloat: *const fn (ptr: *anyopaque) DeserializerError!f32,

        // See IDeserializer.readDouble.
        readDouble: *const fn (ptr: *anyopaque) DeserializerError!f64,

        // See IDeserializer.readBoolean.
        readBoolean: *const fn (ptr: *anyopaque) DeserializerError!bool,

        // See IDeserializer.readUInt8.
        readUInt8: *const fn (ptr: *anyopaque) DeserializerError!u8,

        // See IDeserializer.readString.
        readString: *const fn (ptr: *anyopaque) DeserializerError![]const u8,

        // See IDeserializer.readBuffer.
        readBuffer: *const fn (ptr: *anyopaque) DeserializerError![]const u8,

        // See IDeserializer.readBytes.
        readBytes: *const fn (ptr: *anyopaque, length: usize) DeserializerError![]const u8,

        // See IDeserializer.readBSON.
        readBSON: *const fn (ptr: *anyopaque) DeserializerError!bson.BsonDocument,
    };

    //
    // Read a 32-bit unsigned integer (little-endian)
    //
    pub fn readUInt32(self: IDeserializer) DeserializerError!u32 {
        return self.vtable.readUInt32(self.ptr);
    }

    //
    // Read a 32-bit signed integer (little-endian)
    //
    pub fn readInt32(self: IDeserializer) DeserializerError!i32 {
        return self.vtable.readInt32(self.ptr);
    }

    //
    // Read a 64-bit unsigned integer (little-endian)
    //
    pub fn readUInt64(self: IDeserializer) DeserializerError!u64 {
        return self.vtable.readUInt64(self.ptr);
    }

    //
    // Read a 64-bit signed integer (little-endian)
    //
    pub fn readInt64(self: IDeserializer) DeserializerError!i64 {
        return self.vtable.readInt64(self.ptr);
    }

    //
    // Read a 32-bit float (little-endian)
    //
    pub fn readFloat(self: IDeserializer) DeserializerError!f32 {
        return self.vtable.readFloat(self.ptr);
    }

    //
    // Read a 64-bit double (little-endian)
    //
    pub fn readDouble(self: IDeserializer) DeserializerError!f64 {
        return self.vtable.readDouble(self.ptr);
    }

    //
    // Read a boolean from a single byte
    //
    pub fn readBoolean(self: IDeserializer) DeserializerError!bool {
        return self.vtable.readBoolean(self.ptr);
    }

    //
    // Read an 8-bit unsigned integer
    //
    pub fn readUInt8(self: IDeserializer) DeserializerError!u8 {
        return self.vtable.readUInt8(self.ptr);
    }

    //
    // Read a UTF-8 string (reads 32-bit length prefix first)
    //
    pub fn readString(self: IDeserializer) DeserializerError![]const u8 {
        return self.vtable.readString(self.ptr);
    }

    //
    // Read buffer data (reads 32-bit length prefix first)
    //
    pub fn readBuffer(self: IDeserializer) DeserializerError![]const u8 {
        return self.vtable.readBuffer(self.ptr);
    }

    //
    // Read specified number of raw bytes
    //
    pub fn readBytes(self: IDeserializer, length: usize) DeserializerError![]const u8 {
        return self.vtable.readBytes(self.ptr, length);
    }

    //
    // Read BSON data (reads 32-bit length prefix and deserializes to object)
    //
    pub fn readBSON(self: IDeserializer) DeserializerError!bson.BsonDocument {
        return self.vtable.readBSON(self.ptr);
    }
};

//
// Type definitions for serializer and deserializer functions
// (Zig: the allocator is passed explicitly; `context` stands in for the variables a TypeScript closure captures, such as `this`).
//
pub fn SerializerFunction(comptime T: type) type {
    return *const fn (allocator: std.mem.Allocator, data: T, serializer: ISerializer) anyerror!void;
}

//
// A deserializer function (DeserializerFunction<T>) that also receives a context value.
//
pub fn DeserializerFunction(comptime T: type, comptime ContextT: type) type {
    return *const fn (allocator: std.mem.Allocator, context: ContextT, deserializer: IDeserializer) anyerror!T;
}

//
// Map of version numbers to deserializer functions
// (Zig: one entry of the map; a DeserializerMap is a slice of entries).
//
pub fn DeserializerEntry(comptime T: type, comptime ContextT: type) type {
    return struct {
        // The file version this deserializer reads.
        version: u32,

        // The deserializer for that version.
        deserializer: DeserializerFunction(T, ContextT),
    };
}

// Not ported: MigrationFunction, MigrationMap (no caller passes migrations to load).

//
// Implementation of ISerializer for writing binary data
//
pub const BinarySerializer = struct {
    // Allocates the buffer (and BSON encodings).
    allocator: std.mem.Allocator,

    // The buffer data is written to (only the first `position` bytes are used).
    buffer: []u8,

    // The number of bytes written so far.
    position: usize = 0,

    // The current size of the buffer.
    capacity: usize,

    //
    // Creates a serializer with the given initial buffer capacity (TypeScript default: 1024).
    //
    pub fn init(allocator: std.mem.Allocator, initialCapacity: usize) std.mem.Allocator.Error!BinarySerializer {
        const buffer = try allocator.alloc(u8, initialCapacity);
        @memset(buffer, 0);
        return .{
            .allocator = allocator,
            .buffer = buffer,
            .capacity = initialCapacity,
        };
    }

    //
    // Gets the ISerializer interface of this serializer.
    //
    pub fn asSerializer(self: *BinarySerializer) ISerializer {
        return .{ .ptr = self, .vtable = &binary_serializer_vtable };
    }

    //
    // Grows the buffer so that bytesNeeded more bytes fit
    //
    fn ensureCapacity(self: *BinarySerializer, bytesNeeded: usize) std.mem.Allocator.Error!void {
        if (self.position + bytesNeeded > self.capacity) {
            // Double the capacity until we have enough space
            var newCapacity = self.capacity;
            while (self.position + bytesNeeded > newCapacity) {
                newCapacity *= 2;
            }

            // Create new buffer and copy existing data
            const newBuffer = try self.allocator.alloc(u8, newCapacity);
            @memset(newBuffer, 0);
            @memcpy(newBuffer[0..self.position], self.buffer[0..self.position]);
            self.allocator.free(self.buffer);
            self.buffer = newBuffer;
            self.capacity = newCapacity;
        }
    }

    //
    // Write a 32-bit unsigned integer (little-endian)
    //
    pub fn writeUInt32(self: *BinarySerializer, value: u32) SerializerError!void {
        try self.ensureCapacity(4);
        std.mem.writeInt(u32, self.buffer[self.position..][0..4], value, .little);
        self.position += 4;
    }

    //
    // Write a 32-bit signed integer (little-endian)
    //
    pub fn writeInt32(self: *BinarySerializer, value: i32) SerializerError!void {
        try self.ensureCapacity(4);
        std.mem.writeInt(i32, self.buffer[self.position..][0..4], value, .little);
        self.position += 4;
    }

    //
    // Write a 64-bit unsigned integer (little-endian)
    //
    pub fn writeUInt64(self: *BinarySerializer, value: u64) SerializerError!void {
        try self.ensureCapacity(8);
        std.mem.writeInt(u64, self.buffer[self.position..][0..8], value, .little);
        self.position += 8;
    }

    //
    // Write a 64-bit signed integer (little-endian)
    //
    pub fn writeInt64(self: *BinarySerializer, value: i64) SerializerError!void {
        try self.ensureCapacity(8);
        std.mem.writeInt(i64, self.buffer[self.position..][0..8], value, .little);
        self.position += 8;
    }

    //
    // Write a 32-bit float (little-endian)
    //
    pub fn writeFloat(self: *BinarySerializer, value: f32) SerializerError!void {
        try self.ensureCapacity(4);
        std.mem.writeInt(u32, self.buffer[self.position..][0..4], @bitCast(value), .little);
        self.position += 4;
    }

    //
    // Write a 64-bit double (little-endian)
    //
    pub fn writeDouble(self: *BinarySerializer, value: f64) SerializerError!void {
        try self.ensureCapacity(8);
        std.mem.writeInt(u64, self.buffer[self.position..][0..8], @bitCast(value), .little);
        self.position += 8;
    }

    //
    // Write a boolean as a single byte (1 for true, 0 for false)
    //
    pub fn writeBoolean(self: *BinarySerializer, value: bool) SerializerError!void {
        try self.ensureCapacity(1);
        std.mem.writeInt(u8, self.buffer[self.position..][0..1], if (value) 1 else 0, .little);
        self.position += 1;
    }

    //
    // Write an 8-bit unsigned integer
    //
    pub fn writeUInt8(self: *BinarySerializer, value: u8) SerializerError!void {
        try self.ensureCapacity(1);
        std.mem.writeInt(u8, self.buffer[self.position..][0..1], value, .little);
        self.position += 1;
    }

    //
    // Write a UTF-8 string (prefixed with 32-bit length)
    //
    pub fn writeString(self: *BinarySerializer, value: []const u8) SerializerError!void {
        const stringBuffer = value;
        try self.writeUInt32(@intCast(stringBuffer.len));
        try self.writeBytes(stringBuffer);
    }

    //
    // Write raw buffer data (prefixed with 32-bit length)
    //
    pub fn writeBuffer(self: *BinarySerializer, buffer: []const u8) SerializerError!void {
        try self.writeUInt32(@intCast(buffer.len));
        try self.writeBytes(buffer);
    }

    //
    // Write raw bytes without length prefix
    //
    pub fn writeBytes(self: *BinarySerializer, buffer: []const u8) SerializerError!void {
        try self.ensureCapacity(buffer.len);
        @memcpy(self.buffer[self.position .. self.position + buffer.len], buffer);
        self.position += buffer.len;
    }

    //
    // Write BSON data (serializes object to BSON and writes with 32-bit length prefix)
    //
    pub fn writeBSON(self: *BinarySerializer, obj: bson.BsonDocument) SerializerError!void {
        const bsonBuffer = try bson.serialize(self.allocator, obj);
        try self.writeUInt32(@intCast(bsonBuffer.len));
        try self.writeBytes(bsonBuffer);
    }

    //
    // Returns the bytes written so far
    //
    pub fn getBuffer(self: *BinarySerializer) []u8 {
        // Return only the used portion of the buffer
        return self.buffer[0..self.position];
    }
};

//
// Casts the type erased pointer of an interface back to the implementation.
//
fn implementation(comptime ImplementationT: type, ptr: *anyopaque) *ImplementationT {
    return @ptrCast(@alignCast(ptr));
}

//
// Builds the vtable of an ISerializer implementation from its methods.
//
fn serializerVTable(comptime ImplementationT: type) ISerializer.VTable {
    // Functions that cast the type erased pointer and call the implementation method of the same name.
    const Forward = struct {
        //
        // Write a 32-bit unsigned integer (little-endian)
        //
        fn writeUInt32(ptr: *anyopaque, value: u32) SerializerError!void {
            return implementation(ImplementationT, ptr).writeUInt32(value);
        }

        //
        // Write a 32-bit signed integer (little-endian)
        //
        fn writeInt32(ptr: *anyopaque, value: i32) SerializerError!void {
            return implementation(ImplementationT, ptr).writeInt32(value);
        }

        //
        // Write a 64-bit unsigned integer (little-endian)
        //
        fn writeUInt64(ptr: *anyopaque, value: u64) SerializerError!void {
            return implementation(ImplementationT, ptr).writeUInt64(value);
        }

        //
        // Write a 64-bit signed integer (little-endian)
        //
        fn writeInt64(ptr: *anyopaque, value: i64) SerializerError!void {
            return implementation(ImplementationT, ptr).writeInt64(value);
        }

        //
        // Write a 32-bit float (little-endian)
        //
        fn writeFloat(ptr: *anyopaque, value: f32) SerializerError!void {
            return implementation(ImplementationT, ptr).writeFloat(value);
        }

        //
        // Write a 64-bit double (little-endian)
        //
        fn writeDouble(ptr: *anyopaque, value: f64) SerializerError!void {
            return implementation(ImplementationT, ptr).writeDouble(value);
        }

        //
        // Write a boolean as a single byte (1 for true, 0 for false)
        //
        fn writeBoolean(ptr: *anyopaque, value: bool) SerializerError!void {
            return implementation(ImplementationT, ptr).writeBoolean(value);
        }

        //
        // Write an 8-bit unsigned integer
        //
        fn writeUInt8(ptr: *anyopaque, value: u8) SerializerError!void {
            return implementation(ImplementationT, ptr).writeUInt8(value);
        }

        //
        // Write a UTF-8 string (prefixed with 32-bit length)
        //
        fn writeString(ptr: *anyopaque, value: []const u8) SerializerError!void {
            return implementation(ImplementationT, ptr).writeString(value);
        }

        //
        // Write raw buffer data (prefixed with 32-bit length)
        //
        fn writeBuffer(ptr: *anyopaque, buffer: []const u8) SerializerError!void {
            return implementation(ImplementationT, ptr).writeBuffer(buffer);
        }

        //
        // Write raw bytes without length prefix
        //
        fn writeBytes(ptr: *anyopaque, buffer: []const u8) SerializerError!void {
            return implementation(ImplementationT, ptr).writeBytes(buffer);
        }

        //
        // Write BSON data (serializes object to BSON and writes with 32-bit length prefix)
        //
        fn writeBSON(ptr: *anyopaque, obj: bson.BsonDocument) SerializerError!void {
            return implementation(ImplementationT, ptr).writeBSON(obj);
        }
    };
    return .{
        .writeUInt32 = Forward.writeUInt32,
        .writeInt32 = Forward.writeInt32,
        .writeUInt64 = Forward.writeUInt64,
        .writeInt64 = Forward.writeInt64,
        .writeFloat = Forward.writeFloat,
        .writeDouble = Forward.writeDouble,
        .writeBoolean = Forward.writeBoolean,
        .writeUInt8 = Forward.writeUInt8,
        .writeString = Forward.writeString,
        .writeBuffer = Forward.writeBuffer,
        .writeBytes = Forward.writeBytes,
        .writeBSON = Forward.writeBSON,
    };
}

//
// The ISerializer vtable of BinarySerializer.
//
const binary_serializer_vtable = serializerVTable(BinarySerializer);

//
// CompressedBinarySerializer wraps BinarySerializer and automatically compresses
// the data when finished, writing the compressed length and data to the main serializer.
//
pub const CompressedBinarySerializer = struct {
    // Collects the uncompressed data.
    serializer: BinarySerializer,

    // Receives the compressed length and data when finished.
    mainSerializer: ISerializer,

    //
    // Creates a compressed serializer that writes to mainSerializer (TypeScript default initialCapacity: 1024).
    //
    pub fn init(allocator: std.mem.Allocator, mainSerializer: ISerializer, initialCapacity: usize) std.mem.Allocator.Error!CompressedBinarySerializer {
        return .{
            .mainSerializer = mainSerializer,
            .serializer = try BinarySerializer.init(allocator, initialCapacity),
        };
    }

    //
    // Gets the ISerializer interface of this serializer.
    //
    pub fn asSerializer(self: *CompressedBinarySerializer) ISerializer {
        return .{ .ptr = self, .vtable = &compressed_binary_serializer_vtable };
    }

    //
    // Write a 32-bit unsigned integer (little-endian)
    //
    pub fn writeUInt32(self: *CompressedBinarySerializer, value: u32) SerializerError!void {
        return self.serializer.writeUInt32(value);
    }

    //
    // Write a 32-bit signed integer (little-endian)
    //
    pub fn writeInt32(self: *CompressedBinarySerializer, value: i32) SerializerError!void {
        return self.serializer.writeInt32(value);
    }

    //
    // Write a 64-bit unsigned integer (little-endian)
    //
    pub fn writeUInt64(self: *CompressedBinarySerializer, value: u64) SerializerError!void {
        return self.serializer.writeUInt64(value);
    }

    //
    // Write a 64-bit signed integer (little-endian)
    //
    pub fn writeInt64(self: *CompressedBinarySerializer, value: i64) SerializerError!void {
        return self.serializer.writeInt64(value);
    }

    //
    // Write a 32-bit float (little-endian)
    //
    pub fn writeFloat(self: *CompressedBinarySerializer, value: f32) SerializerError!void {
        return self.serializer.writeFloat(value);
    }

    //
    // Write a 64-bit double (little-endian)
    //
    pub fn writeDouble(self: *CompressedBinarySerializer, value: f64) SerializerError!void {
        return self.serializer.writeDouble(value);
    }

    //
    // Write a boolean as a single byte (1 for true, 0 for false)
    //
    pub fn writeBoolean(self: *CompressedBinarySerializer, value: bool) SerializerError!void {
        return self.serializer.writeBoolean(value);
    }

    //
    // Write an 8-bit unsigned integer
    //
    pub fn writeUInt8(self: *CompressedBinarySerializer, value: u8) SerializerError!void {
        return self.serializer.writeUInt8(value);
    }

    //
    // Write a UTF-8 string (prefixed with 32-bit length)
    //
    pub fn writeString(self: *CompressedBinarySerializer, value: []const u8) SerializerError!void {
        return self.serializer.writeString(value);
    }

    //
    // Write raw buffer data (prefixed with 32-bit length)
    //
    pub fn writeBuffer(self: *CompressedBinarySerializer, buffer: []const u8) SerializerError!void {
        return self.serializer.writeBuffer(buffer);
    }

    //
    // Write raw bytes without length prefix
    //
    pub fn writeBytes(self: *CompressedBinarySerializer, buffer: []const u8) SerializerError!void {
        return self.serializer.writeBytes(buffer);
    }

    //
    // Write BSON data (serializes object to BSON and writes with 32-bit length prefix)
    //
    pub fn writeBSON(self: *CompressedBinarySerializer, obj: bson.BsonDocument) SerializerError!void {
        return self.serializer.writeBSON(obj);
    }

    //
    // Finishes writing, compresses the data, and writes it to the main serializer.
    // This must be called after all data has been written.
    //
    pub fn finish(self: *CompressedBinarySerializer) SerializerError!void {
        const buffer = self.serializer.getBuffer();
        const compressed = try gzipSync(self.serializer.allocator, buffer);
        try self.mainSerializer.writeUInt32(@intCast(compressed.len));
        try self.mainSerializer.writeBytes(compressed);
    }
};

//
// The ISerializer vtable of CompressedBinarySerializer.
//
const compressed_binary_serializer_vtable = serializerVTable(CompressedBinarySerializer);

//
// Compresses data with gzip at level 9 (Node's `gzipSync(buffer, { level: 9 })`), byte-identical to Bun's output.
//
fn gzipSync(allocator: std.mem.Allocator, buffer: []const u8) std.mem.Allocator.Error![]u8 {
    return cloudflare_zlib_deflate.gzipLevel9(allocator, buffer);
}

//
// Gets the message zlib reports for a decompression error (the message of the error `gunzipSync` throws).
//
fn zlibErrorMessage(err: flate.Decompress.Error) []const u8 {
    return switch (err) {
        error.BadGzipHeader, error.BadZlibHeader => "incorrect header check",
        error.WrongGzipChecksum, error.WrongZlibChecksum => "incorrect data check",
        error.WrongGzipSize => "incorrect length check",
        error.EndOfStream, error.ReadFailed => "unexpected end of file",
        error.InvalidBlockType => "invalid block type",
        error.WrongStoredBlockNlen => "invalid stored block lengths",
        error.InvalidDynamicBlockHeader => "too many length or distance symbols",
        error.OversubscribedHuffmanTree, error.IncompleteHuffmanTree => "invalid code lengths set",
        error.InvalidCode => "invalid literal/length code",
        error.InvalidMatch => "invalid distance too far back",
        error.MissingEndOfBlockCode => "invalid code -- missing end-of-block",
    };
}

//
// Decompresses gzip data (Node's `gunzipSync(buffer)`), failing with zlib's error message.
//
fn gunzipSync(allocator: std.mem.Allocator, compressed: []const u8) DeserializerError![]u8 {
    var input: std.Io.Reader = .fixed(compressed);
    var decompressor = flate.Decompress.init(&input, .gzip, &.{});
    const decompressed = decompressor.reader.allocRemaining(allocator, .unlimited) catch |err| {
        if (err == error.OutOfMemory) {
            return error.OutOfMemory;
        }
        // zlib checks the gzip magic bytes as they arrive, so a short input with the wrong magic is a header error.
        const hasBadMagic = (compressed.len >= 1 and compressed[0] != 0x1f) or (compressed.len >= 2 and compressed[1] != 0x8b);
        if (hasBadMagic) {
            return errors.throwError("{s}", .{zlibErrorMessage(error.BadGzipHeader)});
        }
        return errors.throwError("{s}", .{zlibErrorMessage(decompressor.err orelse error.EndOfStream)});
    };

    // zlib checks the gzip trailer (std.compress.flate reads it without checking it).
    const trailer = decompressor.container_metadata.gzip;
    if (trailer.crc != std.hash.Crc32.hash(decompressed)) {
        return errors.throwError("{s}", .{zlibErrorMessage(error.WrongGzipChecksum)});
    }
    if (trailer.count != @as(u32, @truncate(decompressed.len))) {
        return errors.throwError("{s}", .{zlibErrorMessage(error.WrongGzipSize)});
    }
    return decompressed;
}

//
// CompressedBinaryDeserializer reads compressed data from a deserializer,
// decompresses it, and provides a BinaryDeserializer for reading the decompressed data.
//
pub const CompressedBinaryDeserializer = struct {
    // Reads the decompressed data.
    deserializer: BinaryDeserializer,

    //
    // Reads and decompresses the next compressed block of mainDeserializer.
    //
    pub fn init(allocator: std.mem.Allocator, mainDeserializer: IDeserializer) DeserializerError!CompressedBinaryDeserializer {
        // Read compressed length
        const compressedLength = try mainDeserializer.readUInt32();
        // Read compressed data
        const compressed = try mainDeserializer.readBytes(compressedLength);
        // Decompress
        const decompressed = try gunzipSync(allocator, compressed);
        // Create deserializer from decompressed buffer
        return .{ .deserializer = BinaryDeserializer.init(allocator, decompressed) };
    }

    //
    // Gets the IDeserializer interface of this deserializer.
    //
    pub fn asDeserializer(self: *CompressedBinaryDeserializer) IDeserializer {
        return .{ .ptr = self, .vtable = &compressed_binary_deserializer_vtable };
    }

    //
    // Read a 32-bit unsigned integer (little-endian)
    //
    pub fn readUInt32(self: *CompressedBinaryDeserializer) DeserializerError!u32 {
        return self.deserializer.readUInt32();
    }

    //
    // Read a 32-bit signed integer (little-endian)
    //
    pub fn readInt32(self: *CompressedBinaryDeserializer) DeserializerError!i32 {
        return self.deserializer.readInt32();
    }

    //
    // Read a 64-bit unsigned integer (little-endian)
    //
    pub fn readUInt64(self: *CompressedBinaryDeserializer) DeserializerError!u64 {
        return self.deserializer.readUInt64();
    }

    //
    // Read a 64-bit signed integer (little-endian)
    //
    pub fn readInt64(self: *CompressedBinaryDeserializer) DeserializerError!i64 {
        return self.deserializer.readInt64();
    }

    //
    // Read a 32-bit float (little-endian)
    //
    pub fn readFloat(self: *CompressedBinaryDeserializer) DeserializerError!f32 {
        return self.deserializer.readFloat();
    }

    //
    // Read a 64-bit double (little-endian)
    //
    pub fn readDouble(self: *CompressedBinaryDeserializer) DeserializerError!f64 {
        return self.deserializer.readDouble();
    }

    //
    // Read a boolean from a single byte
    //
    pub fn readBoolean(self: *CompressedBinaryDeserializer) DeserializerError!bool {
        return self.deserializer.readBoolean();
    }

    //
    // Read an 8-bit unsigned integer
    //
    pub fn readUInt8(self: *CompressedBinaryDeserializer) DeserializerError!u8 {
        return self.deserializer.readUInt8();
    }

    //
    // Read a UTF-8 string (reads 32-bit length prefix first)
    //
    pub fn readString(self: *CompressedBinaryDeserializer) DeserializerError![]const u8 {
        return self.deserializer.readString();
    }

    //
    // Read buffer data (reads 32-bit length prefix first)
    //
    pub fn readBuffer(self: *CompressedBinaryDeserializer) DeserializerError![]const u8 {
        return self.deserializer.readBuffer();
    }

    //
    // Read specified number of raw bytes
    //
    pub fn readBytes(self: *CompressedBinaryDeserializer, length: usize) DeserializerError![]const u8 {
        return self.deserializer.readBytes(length);
    }

    //
    // Read BSON data (reads 32-bit length prefix and deserializes to object)
    //
    pub fn readBSON(self: *CompressedBinaryDeserializer) DeserializerError!bson.BsonDocument {
        return self.deserializer.readBSON();
    }
};

//
// Implementation of IDeserializer for reading binary data
// (Zig: strings, buffers and bytes are returned as slices of the input buffer; BSON documents are allocated).
//
pub const BinaryDeserializer = struct {
    // Allocates decoded BSON documents.
    allocator: std.mem.Allocator,

    // The data being read.
    buffer: []const u8,

    // The current read position.
    position: usize = 0,

    //
    // Creates a deserializer that reads from buffer.
    //
    pub fn init(allocator: std.mem.Allocator, buffer: []const u8) BinaryDeserializer {
        return .{ .allocator = allocator, .buffer = buffer };
    }

    //
    // Gets the IDeserializer interface of this deserializer.
    //
    pub fn asDeserializer(self: *BinaryDeserializer) IDeserializer {
        return .{ .ptr = self, .vtable = &binary_deserializer_vtable };
    }

    //
    // Read a 32-bit unsigned integer (little-endian)
    //
    pub fn readUInt32(self: *BinaryDeserializer) DeserializerError!u32 {
        try self.checkBounds(4);
        const value = std.mem.readInt(u32, self.buffer[self.position..][0..4], .little);
        self.position += 4;
        return value;
    }

    //
    // Read a 32-bit signed integer (little-endian)
    //
    pub fn readInt32(self: *BinaryDeserializer) DeserializerError!i32 {
        try self.checkBounds(4);
        const value = std.mem.readInt(i32, self.buffer[self.position..][0..4], .little);
        self.position += 4;
        return value;
    }

    //
    // Read a 64-bit unsigned integer (little-endian)
    //
    pub fn readUInt64(self: *BinaryDeserializer) DeserializerError!u64 {
        try self.checkBounds(8);
        const value = std.mem.readInt(u64, self.buffer[self.position..][0..8], .little);
        self.position += 8;
        return value;
    }

    //
    // Read a 64-bit signed integer (little-endian)
    //
    pub fn readInt64(self: *BinaryDeserializer) DeserializerError!i64 {
        try self.checkBounds(8);
        const value = std.mem.readInt(i64, self.buffer[self.position..][0..8], .little);
        self.position += 8;
        return value;
    }

    //
    // Read a 32-bit float (little-endian)
    //
    pub fn readFloat(self: *BinaryDeserializer) DeserializerError!f32 {
        try self.checkBounds(4);
        const value = std.mem.readInt(u32, self.buffer[self.position..][0..4], .little);
        self.position += 4;
        return @bitCast(value);
    }

    //
    // Read a 64-bit double (little-endian)
    //
    pub fn readDouble(self: *BinaryDeserializer) DeserializerError!f64 {
        try self.checkBounds(8);
        const value = std.mem.readInt(u64, self.buffer[self.position..][0..8], .little);
        self.position += 8;
        return @bitCast(value);
    }

    //
    // Read a boolean from a single byte
    //
    pub fn readBoolean(self: *BinaryDeserializer) DeserializerError!bool {
        try self.checkBounds(1);
        const value = std.mem.readInt(u8, self.buffer[self.position..][0..1], .little);
        self.position += 1;
        return value != 0;
    }

    //
    // Read an 8-bit unsigned integer
    //
    pub fn readUInt8(self: *BinaryDeserializer) DeserializerError!u8 {
        try self.checkBounds(1);
        const value = std.mem.readInt(u8, self.buffer[self.position..][0..1], .little);
        self.position += 1;
        return value;
    }

    //
    // Read a UTF-8 string (reads 32-bit length prefix first)
    //
    pub fn readString(self: *BinaryDeserializer) DeserializerError![]const u8 {
        const length = try self.readUInt32();
        try self.checkBounds(length);
        const value = self.buffer[self.position .. self.position + length];
        self.position += length;
        return value;
    }

    //
    // Read buffer data (reads 32-bit length prefix first)
    //
    pub fn readBuffer(self: *BinaryDeserializer) DeserializerError![]const u8 {
        const length = try self.readUInt32();
        try self.checkBounds(length);
        const value = self.buffer[self.position .. self.position + length];
        self.position += length;
        return value;
    }

    //
    // Read specified number of raw bytes
    //
    pub fn readBytes(self: *BinaryDeserializer, length: usize) DeserializerError![]const u8 {
        try self.checkBounds(length);
        const value = self.buffer[self.position .. self.position + length];
        self.position += length;
        return value;
    }

    //
    // Read BSON data (reads 32-bit length prefix and deserializes to object)
    //
    pub fn readBSON(self: *BinaryDeserializer) DeserializerError!bson.BsonDocument {
        const length = try self.readUInt32();
        try self.checkBounds(length);
        const bsonBuffer = self.buffer[self.position .. self.position + length];
        self.position += length;
        return bson.deserialize(self.allocator, bsonBuffer);
    }

    //
    // Throws when fewer than bytesNeeded bytes are left to read
    //
    fn checkBounds(self: *BinaryDeserializer, bytesNeeded: usize) DeserializerError!void {
        if (self.position + bytesNeeded > self.buffer.len) {
            return errors.throwError("Cannot read {d} bytes at position {d}. Buffer length: {d}", .{ bytesNeeded, self.position, self.buffer.len });
        }
    }
};

//
// Builds the vtable of an IDeserializer implementation from its methods.
//
fn deserializerVTable(comptime ImplementationT: type) IDeserializer.VTable {
    // Functions that cast the type erased pointer and call the implementation method of the same name.
    const Forward = struct {
        //
        // Read a 32-bit unsigned integer (little-endian)
        //
        fn readUInt32(ptr: *anyopaque) DeserializerError!u32 {
            return implementation(ImplementationT, ptr).readUInt32();
        }

        //
        // Read a 32-bit signed integer (little-endian)
        //
        fn readInt32(ptr: *anyopaque) DeserializerError!i32 {
            return implementation(ImplementationT, ptr).readInt32();
        }

        //
        // Read a 64-bit unsigned integer (little-endian)
        //
        fn readUInt64(ptr: *anyopaque) DeserializerError!u64 {
            return implementation(ImplementationT, ptr).readUInt64();
        }

        //
        // Read a 64-bit signed integer (little-endian)
        //
        fn readInt64(ptr: *anyopaque) DeserializerError!i64 {
            return implementation(ImplementationT, ptr).readInt64();
        }

        //
        // Read a 32-bit float (little-endian)
        //
        fn readFloat(ptr: *anyopaque) DeserializerError!f32 {
            return implementation(ImplementationT, ptr).readFloat();
        }

        //
        // Read a 64-bit double (little-endian)
        //
        fn readDouble(ptr: *anyopaque) DeserializerError!f64 {
            return implementation(ImplementationT, ptr).readDouble();
        }

        //
        // Read a boolean from a single byte
        //
        fn readBoolean(ptr: *anyopaque) DeserializerError!bool {
            return implementation(ImplementationT, ptr).readBoolean();
        }

        //
        // Read an 8-bit unsigned integer
        //
        fn readUInt8(ptr: *anyopaque) DeserializerError!u8 {
            return implementation(ImplementationT, ptr).readUInt8();
        }

        //
        // Read a UTF-8 string (reads 32-bit length prefix first)
        //
        fn readString(ptr: *anyopaque) DeserializerError![]const u8 {
            return implementation(ImplementationT, ptr).readString();
        }

        //
        // Read buffer data (reads 32-bit length prefix first)
        //
        fn readBuffer(ptr: *anyopaque) DeserializerError![]const u8 {
            return implementation(ImplementationT, ptr).readBuffer();
        }

        //
        // Read specified number of raw bytes
        //
        fn readBytes(ptr: *anyopaque, length: usize) DeserializerError![]const u8 {
            return implementation(ImplementationT, ptr).readBytes(length);
        }

        //
        // Read BSON data (reads 32-bit length prefix and deserializes to object)
        //
        fn readBSON(ptr: *anyopaque) DeserializerError!bson.BsonDocument {
            return implementation(ImplementationT, ptr).readBSON();
        }
    };
    return .{
        .readUInt32 = Forward.readUInt32,
        .readInt32 = Forward.readInt32,
        .readUInt64 = Forward.readUInt64,
        .readInt64 = Forward.readInt64,
        .readFloat = Forward.readFloat,
        .readDouble = Forward.readDouble,
        .readBoolean = Forward.readBoolean,
        .readUInt8 = Forward.readUInt8,
        .readString = Forward.readString,
        .readBuffer = Forward.readBuffer,
        .readBytes = Forward.readBytes,
        .readBSON = Forward.readBSON,
    };
}

//
// The IDeserializer vtable of BinaryDeserializer.
//
const binary_deserializer_vtable = deserializerVTable(BinaryDeserializer);

//
// The IDeserializer vtable of CompressedBinaryDeserializer.
//
const compressed_binary_deserializer_vtable = deserializerVTable(CompressedBinaryDeserializer);

//
// Error thrown when no deserializer is found for a version
// (Zig: returned as error.Thrown with the error name "UnsupportedVersionError" recorded; check errors.lastErrorName()).
//
pub const UnsupportedVersionError = struct {
    //
    // Records the error message and returns the error (TypeScript: `throw new UnsupportedVersionError(...)`).
    //
    pub fn throw(version: u32, availableVersions: []const u32, fileName: []const u8) errors.ThrownError {
        errors.recordError("UnsupportedVersionError", "No deserializer found for version {d} from file {s}. Available versions: {f}", .{ version, fileName, VersionList{ .versions = availableVersions } });
        return error.Thrown;
    }
};

//
// Formats a list of versions like JavaScript's `versions.join(', ')`.
//
const VersionList = struct {
    // The versions to format.
    versions: []const u32,

    //
    // Writes the versions separated by ", ".
    //
    pub fn format(self: VersionList, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.versions, 0..) |version, index| {
            if (index > 0) {
                try writer.writeAll(", ");
            }
            try writer.print("{d}", .{version});
        }
    }
};

//
// V6 layout: [version 4][type 4][payload][checksum 32]. Type is 4-byte ASCII. Checksum covers version + type + payload.
//
const TYPE_CODE_LENGTH = 4;

//
// Checks that a type code is exactly 4 characters and returns its bytes
//
fn typeCodeToBuffer(typeCode: []const u8) errors.ThrownError![]const u8 {
    if (typeCode.len != TYPE_CODE_LENGTH) {
        return errors.throwError("Type code must be exactly {d} ASCII characters, got \"{s}\" (length {d})", .{ TYPE_CODE_LENGTH, typeCode, typeCode.len });
    }
    return typeCode;
}

//
// Computes the SHA-256 digest of data (`createHash('sha256').update(data).digest()`).
//
fn sha256(data: []const u8) [Sha256.digest_length]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    return digest;
}

//
// The retry operation that writes a file to storage (TypeScript: `() => storage.write(filePath, undefined, finalBuffer)`).
//
fn WriteOperation(comptime StorageT: type) type {
    return struct {
        // The allocator for the storage operation.
        allocator: std.mem.Allocator,

        // The storage to write to.
        storage: StorageT,

        // The path of the file to write.
        filePath: []const u8,

        // The data to write.
        data: []const u8,

        //
        // Writes the file.
        //
        pub fn run(self: *const @This(), io: std.Io) anyerror!void {
            return self.storage.write(self.allocator, io, self.filePath, null, self.data);
        }
    };
}

//
// The retry operation that reads a file from storage (TypeScript: `() => storage.read(filePath)`).
//
fn ReadOperation(comptime StorageT: type) type {
    return struct {
        // The storage to read from.
        storage: StorageT,

        // Allocates the file data.
        allocator: std.mem.Allocator,

        // The path of the file to read.
        filePath: []const u8,

        //
        // Reads the file (null when it does not exist).
        //
        pub fn run(self: *const @This(), io: std.Io) anyerror!?[]u8 {
            return self.storage.read(self.allocator, io, self.filePath);
        }
    };
}

//
// The storage methods used by this file. `storage: anytype` must provide methods named like the TypeScript IStorage
// methods (storage-zig's IStorage satisfies this):
//
//   read(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?[]u8
//       The whole file (allocated with allocator) or null when it does not exist.
//   write(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, data: []const u8) !void
//   readStream(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !Stream
//       Where Stream (a value or pointer) has `reader() *std.Io.Reader` and `destroy(io: std.Io) void`
//       (TypeScript: `stream.destroy()`). Errors opening or reading the stream count as a failed stream.
//

//
// Saves data to storage with v6 layout: [version 4][type 4][payload][checksum 32].
// Always writes checksum covering version + type + payload.
//
pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    storage: anytype,
    filePath: []const u8,
    data: anytype,
    version: u32,
    typeCode: []const u8,
    serializer: SerializerFunction(@TypeOf(data)),
) anyerror!void {
    var binarySerializer = try BinarySerializer.init(allocator, 1024);

    try binarySerializer.writeUInt32(version);
    try binarySerializer.writeBytes(try typeCodeToBuffer(typeCode));
    try serializer(allocator, data, binarySerializer.asSerializer());

    const serializedData = binarySerializer.getBuffer();
    const checksum = sha256(serializedData);
    const finalBuffer = try std.mem.concat(allocator, u8, &.{ serializedData, &checksum });

    const operation: WriteOperation(@TypeOf(storage)) = .{ .allocator = allocator, .storage = storage, .filePath = filePath, .data = finalBuffer };
    try retry(io, &operation, 3, 1_000, 2, 30_000, null);
}

//
// Finds the deserializer for a version (TypeScript: `deserializers[version]`).
//
fn findDeserializer(comptime T: type, comptime ContextT: type, deserializers: []const DeserializerEntry(T, ContextT), version: u32) ?DeserializerFunction(T, ContextT) {
    for (deserializers) |entry| {
        if (entry.version == version) {
            return entry.deserializer;
        }
    }
    return null;
}

//
// Loads data from storage. Prefers v6 layout [version][type][payload][checksum]; falls back to legacy [version][payload][checksum] for pre-v6 databases.
// (Zig: `context` is passed to every deserializer; the `migrations` and `targetVersion` parameters are not ported
// because no caller passes migrations, and without migrations they have no effect.)
//
pub fn load(
    comptime T: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    storage: anytype,
    filePath: []const u8,
    expectedTypeCode: []const u8,
    context: anytype,
    deserializers: []const DeserializerEntry(T, @TypeOf(context)),
) anyerror!?T {
    const ContextT = @TypeOf(context);

    const readOperation: ReadOperation(@TypeOf(storage)) = .{ .storage = storage, .allocator = allocator, .filePath = filePath };
    const buffer = try retry(io, &readOperation, 3, 1_000, 2, 30_000, null) orelse {
        return null;
    };

    if (buffer.len < 4) {
        return errors.throwError("File '{s}' is too small. File has {d} bytes, minimum 4.", .{ filePath, buffer.len });
    }

    const availableVersions = try allocator.alloc(u32, deserializers.len);
    for (deserializers, 0..) |entry, index| {
        availableVersions[index] = entry.version;
    }
    std.mem.sort(u32, availableVersions, {}, std.sort.desc(u32));
    // Not ported: finalTargetVersion (only used by applyMigrations).

    var version: u32 = undefined;
    var payload: []const u8 = undefined;

    const v6MinLength = 4 + TYPE_CODE_LENGTH + 32;
    if (buffer.len >= v6MinLength) {
        const dataBuffer = buffer[0 .. buffer.len - 32];
        const calculatedChecksum = sha256(dataBuffer);
        const storedChecksum = buffer[buffer.len - 32 ..];
        if (std.mem.eql(u8, &calculatedChecksum, storedChecksum)) {
            const typeCode = dataBuffer[4 .. 4 + TYPE_CODE_LENGTH];
            if (std.mem.eql(u8, typeCode, expectedTypeCode)) {
                version = std.mem.readInt(u32, dataBuffer[0..4], .little);
                payload = dataBuffer[4 + TYPE_CODE_LENGTH ..];
                const deserializerFunction = findDeserializer(T, ContextT, deserializers, version) orelse {
                    return UnsupportedVersionError.throw(version, availableVersions, filePath);
                };
                var binaryDeserializer = BinaryDeserializer.init(allocator, payload);
                const data = try deserializerFunction(allocator, context, binaryDeserializer.asDeserializer());
                // Not ported: applyMigrations (no caller passes migrations).
                return data;
            }
        }
    }

    // Legacy format: [version 4][payload] or [version 4][payload][checksum 32]
    if (buffer.len >= 36) {
        const dataBuffer = buffer[0 .. buffer.len - 32];
        const calculatedChecksum = sha256(dataBuffer);
        const storedChecksum = buffer[buffer.len - 32 ..];
        if (std.mem.eql(u8, &calculatedChecksum, storedChecksum)) {
            version = std.mem.readInt(u32, dataBuffer[0..4], .little);
            payload = dataBuffer[4..];
        }
        else {
            // No checksum (e.g. pre-checksum v2): try [version 4][payload]; only accept if deserialization succeeds
            const legacyVersion = std.mem.readInt(u32, buffer[0..4], .little);
            const legacyPayload = buffer[4..];
            if (findDeserializer(T, ContextT, deserializers, legacyVersion)) |legacyDeserializer| {
                var binaryDeserializer = BinaryDeserializer.init(allocator, legacyPayload);
                if (legacyDeserializer(allocator, context, binaryDeserializer.asDeserializer())) |data| {
                    // Not ported: applyMigrations (no caller passes migrations).
                    return data;
                }
                else |_| {
                    // Deserialization failed; treat as corrupted legacy-with-checksum and throw
                }
            }
            return errors.throwError("Checksum mismatch: expected {x}, got {x}", .{ storedChecksum, &calculatedChecksum });
        }
    }
    else {
        version = std.mem.readInt(u32, buffer[0..4], .little);
        payload = buffer[4..];
    }

    const deserializerFunction = findDeserializer(T, ContextT, deserializers, version) orelse {
        return UnsupportedVersionError.throw(version, availableVersions, filePath);
    };

    var binaryDeserializer = BinaryDeserializer.init(allocator, payload);
    const data = try deserializerFunction(allocator, context, binaryDeserializer.asDeserializer());

    // Not ported: applyMigrations (no caller passes migrations).

    return data;
}

//
// Loads only the per-file version number (first 4 bytes) from a versioned serialized file.
// Uses a stream so only the first 4 bytes are read, not the entire file.
// This is the single place that reads the version header; callers use this instead of
// reading the version bytes directly.
//
pub fn loadVersion(allocator: std.mem.Allocator, io: std.Io, storage: anytype, filePath: []const u8) ?u32 {
    // (Zig: FileStorage opens the file in readStream where Node opens it on the first read and reports a failure
    // through the stream's 'error' event, so a failure of readStream resolves undefined like that event.)
    const stream = storage.readStream(allocator, io, filePath) catch {
        return null;
    };
    defer stream.destroy(io);

    var versionBuffer: [4]u8 = undefined;
    stream.reader().readSliceAll(&versionBuffer) catch {
        // Fewer than 4 bytes before the end of the stream, or a stream error.
        return null;
    };
    return std.mem.readInt(u32, &versionBuffer, .little);
}

//
// Verifies a serialized file's integrity (checksum and/or version header).
// Similar to load() but doesn't deserialize the data.
//
pub const IVerifyResult = struct {
    // True when the file is a complete v6 file with a matching checksum.
    valid: bool,

    // The size of the file in bytes (0 when it was not found).
    size: u64,

    // Why the file is invalid (null when valid).
    @"error": ?[]const u8 = null,
};

//
// Verifies a serialized file's integrity (see IVerifyResult)
//
pub fn verify(
    allocator: std.mem.Allocator,
    io: std.Io,
    storage: anytype,
    filePath: []const u8,
) anyerror!IVerifyResult {
    const readOperation: ReadOperation(@TypeOf(storage)) = .{ .storage = storage, .allocator = allocator, .filePath = filePath };
    const buffer = try retry(io, &readOperation, 3, 1_000, 2, 30_000, null) orelse {
        return .{ .valid = false, .size = 0, .@"error" = "File not found or empty" };
    };

    const minLength = 4 + TYPE_CODE_LENGTH + 32;
    if (buffer.len < minLength) {
        return .{
            .valid = false,
            .size = buffer.len,
            .@"error" = try std.fmt.allocPrint(allocator, "File too small for v6 format ({d} bytes, minimum {d})", .{ buffer.len, minLength }),
        };
    }

    const dataBuffer = buffer[0 .. buffer.len - 32];
    const calculatedChecksum = sha256(dataBuffer);
    const storedChecksum = buffer[buffer.len - 32 ..];
    if (!std.mem.eql(u8, &calculatedChecksum, storedChecksum)) {
        return .{
            .valid = false,
            .size = buffer.len,
            .@"error" = try std.fmt.allocPrint(allocator, "Checksum mismatch: expected {x}, got {x}", .{ storedChecksum, &calculatedChecksum }),
        };
    }

    return .{ .valid = true, .size = buffer.len };
}

// Not ported: applyMigrations, findMigrationPath (only reached when load is given migrations, which no caller does).
