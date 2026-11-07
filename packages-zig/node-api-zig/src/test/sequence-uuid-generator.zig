const std = @import("std");
const utils = @import("utils-zig");

//
// A uuid generator that hands out the ids it was given, in order, and repeats the last one when they run out.
//
pub const SequenceUuidGenerator = struct {
    // The ids to hand out.
    ids: []const []const u8,

    // The index of the next id to hand out.
    next: usize = 0,

    //
    // Gets the IUuidGenerator interface for this generator.
    //
    pub fn uuidGenerator(self: *SequenceUuidGenerator) utils.uuid_generator.IUuidGenerator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The IUuidGenerator functions of this generator.
    //
    const vtable: utils.uuid_generator.IUuidGenerator.VTable = .{
        .generate = generate,
    };

    //
    // Hands out the next id.
    //
    fn generate(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror![]const u8 {
        _ = io;
        const self: *SequenceUuidGenerator = @ptrCast(@alignCast(ptr));
        const index = @min(self.next, self.ids.len - 1);
        self.next += 1;
        return allocator.dupe(u8, self.ids[index]);
    }
};
