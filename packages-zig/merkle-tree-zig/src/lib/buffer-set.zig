const std = @import("std");
const utils = @import("utils-zig");
const errors = utils.errors;

//
// Returns the index of the first buffer in a bucket with the same content, or null when there is none.
// (Zig: stands in for the JavaScript array method `bucket.some(b => b.equals(buffer))`.)
//
fn findBufferIndex(bucket: []const []const u8, buffer: []const u8) ?usize {
    for (bucket, 0..) |bucketBuffer, index| {
        if (std.mem.eql(u8, bucketBuffer, buffer)) {
            return index;
        }
    }
    return null;
}

//
// A Set implementation that uses Buffer content (not reference) for membership testing.
// Uses a numeric hash derived from all bytes of the buffer for fast lookups.
// Handles collisions by storing full buffers and comparing on collision.
//
// Optimized for SHA-256 hashes (32 bytes).
//
pub const BufferSet = struct {
    // Allocates the buckets.
    allocator: std.mem.Allocator,

    // The buffers in buckets keyed by their numeric hash (TypeScript: `Map<number, Buffer[]>`; the array hash map
    // iterates in insertion order like a JavaScript Map).
    _map: std.AutoArrayHashMapUnmanaged(u32, std.ArrayList([]const u8)),

    //
    // Creates an empty set (TypeScript: the constructor).
    //
    pub fn init(allocator: std.mem.Allocator) BufferSet {
        return .{ .allocator = allocator, ._map = .empty };
    }

    //
    // Create a numeric hash by XORing all 32-bit chunks of the buffer
    // Optimized for SHA-256 (32 bytes) - loop unrolled for maximum performance
    //
    fn _hash(buffer: []const u8) errors.ThrownError!u32 {
        if (buffer.len != 32) {
            return errors.throwError("BufferSet expects 32-byte hashes (SHA-256), got {d} bytes", .{buffer.len});
        }

        // For SHA-256 hashes (32 bytes), XOR all 8 chunks
        return std.mem.readInt(u32, buffer[0..4], .big) ^
            std.mem.readInt(u32, buffer[4..8], .big) ^
            std.mem.readInt(u32, buffer[8..12], .big) ^
            std.mem.readInt(u32, buffer[12..16], .big) ^
            std.mem.readInt(u32, buffer[16..20], .big) ^
            std.mem.readInt(u32, buffer[20..24], .big) ^
            std.mem.readInt(u32, buffer[24..28], .big) ^
            std.mem.readInt(u32, buffer[28..32], .big);
    }

    //
    // Adds a buffer to the set (does nothing when it is already present).
    //
    pub fn add(self: *BufferSet, buffer: []const u8) !*BufferSet {
        const hash = try _hash(buffer);
        const bucket = self._map.getPtr(hash);

        if (bucket == null) {
            var newBucket: std.ArrayList([]const u8) = .empty;
            try newBucket.append(self.allocator, buffer);
            try self._map.put(self.allocator, hash, newBucket);
        }
        else {
            // Check if buffer already exists in bucket
            const exists = findBufferIndex(bucket.?.items, buffer) != null;
            if (!exists) {
                try bucket.?.append(self.allocator, buffer);
            }
        }
        return self;
    }

    // Not ported: has (not reached by psi replicate or psi verify)

    // Not ported: delete (not reached by psi replicate or psi verify)

    // Not ported: clear (not reached by psi replicate or psi verify)

    // Not ported: size (not reached by psi replicate or psi verify)

    // Not ported: forEach (not reached by psi replicate or psi verify)

    //
    // Iterates the buffers in the set (the Zig form of the TypeScript generator).
    //
    pub fn values(self: *const BufferSet) ValueIterator {
        return .{ .buckets = self._map.values(), .bucketIndex = 0, .bufferIndex = 0 };
    }

    // Not ported: keys (not reached by psi replicate or psi verify)

    // Not ported: entries (not reached by psi replicate or psi verify)

    //
    // Iterator returned by values().
    //
    pub const ValueIterator = struct {
        // The buckets being iterated.
        buckets: []const std.ArrayList([]const u8),

        // The index of the current bucket.
        bucketIndex: usize,

        // The index of the next buffer in the current bucket.
        bufferIndex: usize,

        //
        // Returns the next buffer or null when finished.
        //
        pub fn next(self: *ValueIterator) ?[]const u8 {
            while (self.bucketIndex < self.buckets.len) {
                const bucket = self.buckets[self.bucketIndex].items;
                if (self.bufferIndex < bucket.len) {
                    const buffer = bucket[self.bufferIndex];
                    self.bufferIndex += 1;
                    return buffer;
                }
                self.bucketIndex += 1;
                self.bufferIndex = 0;
            }
            return null;
        }
    };
};
