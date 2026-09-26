const std = @import("std");
const utils = @import("utils-zig");
const errors = utils.errors;

//
// A Map implementation that uses Buffers as keys.
// Optimized for SHA-256 hashes (32 bytes).
//
// Similar to how Map relates to Set in JavaScript,
// BufferMap relates to BufferSet - storing key-value pairs
// where keys are Buffers.
//
pub fn BufferMap(comptime V: type) type {
    return struct {
        const Self = @This();

        // Allocates the buckets.
        allocator: std.mem.Allocator,

        // The [key, value] pairs in buckets keyed by the numeric hash of the key (TypeScript:
        // `Map<number, Array<[Buffer, V]>>`; the array hash map iterates in insertion order like a JavaScript Map).
        _map: std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(Entry)),

        //
        // Creates an empty map (TypeScript: the constructor).
        //
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, ._map = .empty };
        }

        //
        // Create a numeric hash by XORing all 32-bit chunks of the buffer
        // Optimized for SHA-256 (32 bytes) - loop unrolled for maximum performance
        //
        fn _hash(buffer: []const u8) errors.ThrownError!u32 {
            if (buffer.len != 32) {
                return errors.throwError("BufferMap expects 32-byte hashes (SHA-256), got {d} bytes", .{buffer.len});
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
        // Returns the index of the entry in a bucket whose key has the same content, or null when there is none.
        // (Zig: stands in for the JavaScript array methods `bucket.findIndex(([k]) => k.equals(key))`
        // and `bucket.find(...)`.)
        //
        fn findEntryIndex(bucket: []const Entry, key: []const u8) ?usize {
            for (bucket, 0..) |entry, index| {
                if (std.mem.eql(u8, entry.key, key)) {
                    return index;
                }
            }
            return null;
        }

        //
        // Sets the value for a key (replacing any existing value).
        //
        pub fn set(self: *Self, key: []const u8, value: V) !*Self {
            const hash = try _hash(key);
            const bucket = self._map.getPtr(hash);

            if (bucket == null) {
                var newBucket: std.ArrayList(Entry) = .empty;
                try newBucket.append(self.allocator, .{ .key = key, .value = value });
                try self._map.put(self.allocator, hash, newBucket);
            }
            else {
                // Check if key already exists in bucket
                const index = findEntryIndex(bucket.?.items, key);
                if (index) |existingIndex| {
                    // Update existing value
                    bucket.?.items[existingIndex].value = value;
                }
                else {
                    // Add new key-value pair
                    try bucket.?.append(self.allocator, .{ .key = key, .value = value });
                }
            }
            return self;
        }

        //
        // Gets the value for a key (null when the key is not present).
        //
        pub fn get(self: *const Self, key: []const u8) !?V {
            const hash = try _hash(key);
            const bucket = self._map.getPtr(hash) orelse {
                return null;
            };

            const index = findEntryIndex(bucket.items, key) orelse {
                return null;
            };
            return bucket.items[index].value;
        }

        // Not ported: has (not reached by psi replicate or psi verify)

        // Not ported: delete (not reached by psi replicate or psi verify)

        // Not ported: clear (not reached by psi replicate or psi verify)

        // Not ported: size (not reached by psi replicate or psi verify)

        // Not ported: forEach (not reached by psi replicate or psi verify)

        // Not ported: values (not reached by psi replicate or psi verify)

        // Not ported: keys (not reached by psi replicate or psi verify)

        // Not ported: entries (not reached by psi replicate or psi verify)

        //
        // One [key, value] pair of the map (TypeScript: `[Buffer, V]`).
        //
        pub const Entry = struct {
            // The key.
            key: []const u8,

            // The value.
            value: V,
        };
    };
}
