const std = @import("std");

//
// The iterator returned by batchGenerator (TypeScript: the async generator batchGenerator returns).
// `SourceT` is a pointer to an iterator whose `next()` returns `!?T`.
//
pub fn BatchGenerator(comptime T: type, comptime SourceT: type) type {
    return struct {
        // Allocates the batches.
        allocator: std.mem.Allocator,

        // The iterator whose items are batched.
        source: SourceT,

        // The most items a batch holds.
        batchSize: usize,

        // True once the source is exhausted and the final batch has been yielded.
        done: bool,

        //
        // Returns the next batch, or null when every item has been yielded.
        //
        pub fn next(self: *@This()) !?[]T {
            if (self.done) {
                return null;
            }

            var batch: std.ArrayList(T) = .empty;

            while (try self.source.next()) |item| {
                try batch.append(self.allocator, item);

                if (batch.items.len >= self.batchSize) {
                    return batch.items;
                }
            }

            self.done = true;

            if (batch.items.len > 0) {
                return batch.items;
            }

            return null;
        }
    };
}

//
// Consumes an async generator and yields its items in fixed-size batches.
// The final batch may be smaller than batchSize if the source is exhausted.
// (Zig: `source` is a pointer to an iterator whose `next()` returns `!?T`, and the result is an iterator whose
// `next` yields each batch, like iterating the TypeScript generator.)
//
pub fn batchGenerator(comptime T: type, allocator: std.mem.Allocator, source: anytype, batchSize: usize) BatchGenerator(T, @TypeOf(source)) {
    return .{
        .allocator = allocator,
        .source = source,
        .batchSize = batchSize,
        .done = false,
    };
}
