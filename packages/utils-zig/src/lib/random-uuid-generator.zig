const std = @import("std");
const uuid_generator = @import("uuid-generator.zig");

//
// Random UUID generator (version 4 UUIDs from the Io implementation's cryptographically secure random source).
//
pub const RandomUuidGenerator = struct {
    // Unused. Present because an IUuidGenerator must point at a value with an address.
    unused: u8 = 0,

    //
    // Gets the IUuidGenerator interface for this generator.
    //
    pub fn uuidGenerator(self: *RandomUuidGenerator) uuid_generator.IUuidGenerator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The IUuidGenerator functions of this generator.
    //
    const vtable: uuid_generator.IUuidGenerator.VTable = .{
        .generate = generateErased,
    };

    //
    // Generates a random version 4 UUID, formatted like `uuidv4()` (lower case hex with dashes).
    //
    pub fn generate(self: *RandomUuidGenerator, allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
        _ = self;
        var bytes: [16]u8 = undefined;
        io.random(&bytes);

        // Version 4.
        bytes[6] = (bytes[6] & 0x0f) | 0x40;

        // Variant 10xx (RFC 4122).
        bytes[8] = (bytes[8] & 0x3f) | 0x80;

        const hex = std.fmt.bytesToHex(bytes, .lower);
        return std.fmt.allocPrint(allocator, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
    }

    //
    // Type-erased generate for the vtable.
    //
    fn generateErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror![]const u8 {
        const self: *RandomUuidGenerator = @ptrCast(@alignCast(ptr));
        return self.generate(allocator, io);
    }
};
