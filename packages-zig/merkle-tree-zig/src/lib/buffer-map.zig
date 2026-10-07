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

        //
        // Returns true when the key is present.
        //
        pub fn has(self: *const Self, key: []const u8) !bool {
            return (try self.get(key)) != null;
        }

        //
        // Removes the key. Returns false when it is not present.
        //
        pub fn delete(self: *Self, key: []const u8) !bool {
            const hash = try _hash(key);
            const bucket = self._map.getPtr(hash) orelse {
                return false;
            };

            const index = findEntryIndex(bucket.items, key) orelse {
                return false;
            };

            _ = bucket.orderedRemove(index);

            // Remove bucket if empty
            if (bucket.items.len == 0) {
                _ = self._map.orderedRemove(hash);
            }

            return true;
        }

        //
        // Removes every entry.
        //
        pub fn clear(self: *Self) void {
            self._map.clearRetainingCapacity();
        }

        //
        // Returns the number of entries (TypeScript: the `size` getter).
        //
        pub fn size(self: *const Self) usize {
            var total: usize = 0;
            for (self._map.values()) |bucket| {
                total += bucket.items.len;
            }
            return total;
        }

        //
        // Calls the callback with each [key, value] pair.
        //
        pub fn forEach(self: *const Self, context: anytype, callback: *const fn (@TypeOf(context), Entry) anyerror!void) !void {
            var entryIterator = self.entries();
            while (entryIterator.next()) |entry| {
                try callback(context, entry);
            }
        }

        //
        // Iterates the values.
        //
        pub fn values(self: *const Self) ValueIterator {
            return .{
                .entryIterator = self.entries(),
            };
        }

        //
        // Iterates the keys.
        //
        pub fn keys(self: *const Self) KeyIterator {
            return .{
                .entryIterator = self.entries(),
            };
        }

        //
        // Iterates the [key, value] pairs (TypeScript: `entries()`, also what `for...of` iterates).
        //
        pub fn entries(self: *const Self) EntryIterator {
            return .{
                .buckets = self._map.values(),
                .bucketIndex = 0,
                .entryIndex = 0,
            };
        }

        //
        // Iterator returned by entries().
        //
        pub const EntryIterator = struct {
            // The buckets being iterated.
            buckets: []const std.ArrayList(Entry),

            // The index of the current bucket.
            bucketIndex: usize,

            // The index of the next entry in the current bucket.
            entryIndex: usize,

            //
            // Returns the next pair or null when finished.
            //
            pub fn next(self: *EntryIterator) ?Entry {
                while (self.bucketIndex < self.buckets.len) {
                    const bucket = self.buckets[self.bucketIndex].items;
                    if (self.entryIndex < bucket.len) {
                        const entry = bucket[self.entryIndex];
                        self.entryIndex += 1;
                        return entry;
                    }
                    self.bucketIndex += 1;
                    self.entryIndex = 0;
                }
                return null;
            }
        };

        //
        // Iterator returned by values().
        //
        pub const ValueIterator = struct {
            // The iterator over the pairs.
            entryIterator: EntryIterator,

            //
            // Returns the next value or null when finished.
            //
            pub fn next(self: *ValueIterator) ?V {
                const entry = self.entryIterator.next() orelse {
                    return null;
                };
                return entry.value;
            }
        };

        //
        // Iterator returned by keys().
        //
        pub const KeyIterator = struct {
            // The iterator over the pairs.
            entryIterator: EntryIterator,

            //
            // Returns the next key or null when finished.
            //
            pub fn next(self: *KeyIterator) ?[]const u8 {
                const entry = self.entryIterator.next() orelse {
                    return null;
                };
                return entry.key;
            }
        };

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
