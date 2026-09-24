const std = @import("std");

//
// Interface for UUID generation
//
pub const IUuidGenerator = struct {
    // The UUID generator implementation.
    ptr: *anyopaque,

    // The functions of the UUID generator implementation.
    vtable: *const VTable,

    //
    // The functions a UUID generator implementation provides.
    //
    pub const VTable = struct {
        // Generates a UUID string allocated with `allocator`.
        generate: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror![]const u8,
    };

    //
    // Generates a UUID string allocated with `allocator`.
    //
    pub fn generate(self: IUuidGenerator, allocator: std.mem.Allocator, io: std.Io) anyerror![]const u8 {
        return self.vtable.generate(self.ptr, allocator, io);
    }
};
