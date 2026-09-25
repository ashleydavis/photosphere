const std = @import("std");
const uuid_generator = @import("uuid-generator.zig");

//
// Equivalent of the JavaScript ToUint32 conversion (used by `>>>` and `>>> 0`) of a number.
//
pub fn jsToUint32(value: f64) u32 {
    if (!std.math.isFinite(value)) {
        return 0;
    }
    const truncated = @trunc(value);
    const modulo = @mod(truncated, 4294967296.0);
    return @intFromFloat(modulo);
}

//
// Equivalent of the JavaScript ToInt32 conversion (used by `^`, `&` and `|`) of a number.
//
pub fn jsToInt32(value: f64) i32 {
    return @bitCast(jsToUint32(value));
}

//
// Equivalent of JavaScript `(left ^ right)` where the result is multiplied as a double.
//
fn jsXor(left: f64, right: f64) f64 {
    return @floatFromInt(jsToInt32(left) ^ jsToInt32(right));
}

//
// Equivalent of JavaScript `(value >>> shift)`.
//
fn jsUnsignedShiftRight(value: f64, shift: u5) f64 {
    return @floatFromInt(jsToUint32(value) >> shift);
}

//
// Browser-safe test UUID generator that creates deterministic UUIDs with good shard
// distribution. Uses an in-memory counter so the class is safe to import into the
// renderer/Vite bundle (the file-backed TestUuidGenerator in node-utils cannot run
// in a browser context because it depends on fs/path). Each instance counts from
// zero independently.
//
pub const TestUuidGenerator = struct {
    // Monotonically increasing counter incremented on every generate() call.
    counter: i64 = 0,

    //
    // Gets the IUuidGenerator interface for this generator.
    //
    pub fn uuidGenerator(self: *TestUuidGenerator) uuid_generator.IUuidGenerator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The IUuidGenerator functions of this generator.
    //
    const vtable: uuid_generator.IUuidGenerator.VTable = .{
        .generate = generateErased,
    };

    //
    // Generates the next deterministic UUID.
    //
    pub fn generate(self: *TestUuidGenerator, allocator: std.mem.Allocator) ![]const u8 {
        self.counter += 1;
        return generateDeterministicUuid(allocator, self.counter);
    }

    //
    // Restarts the counter so subsequent ids match the first sequence.
    //
    pub fn reset(self: *TestUuidGenerator) void {
        self.counter = 0;
    }

    //
    // Generates the UUID for a counter value. Reproduces the JavaScript number semantics exactly:
    // multiplications are double precision, bitwise operators convert with ToInt32/ToUint32.
    // Public (private in TypeScript) so the file-backed TestUuidGenerator in node-utils-zig can share it.
    //
    pub fn generateDeterministicUuid(allocator: std.mem.Allocator, counter: i64) ![]const u8 {
        // Use multiple hash functions to create good distribution
        // Golden ratio multiplier for good distribution
        const phi: f64 = 0x9e3779b9;
        const counter_number: f64 = @floatFromInt(counter);

        // Create multiple hash values from the counter
        const hash1_initial = counter_number * phi;
        const hash2_initial = jsXor(counter_number, 0xaaaaaaaa) * phi;
        const hash3_initial = jsXor(counter_number, 0x55555555) * phi;

        // Apply additional mixing to improve distribution
        var hash1 = jsToUint32(jsXor(hash1_initial, jsUnsignedShiftRight(hash1_initial, 16)) * 0x85ebca6b);
        var hash2 = jsToUint32(jsXor(hash2_initial, jsUnsignedShiftRight(hash2_initial, 16)) * 0xc2b2ae35);
        var hash3 = jsToUint32(jsXor(hash3_initial, jsUnsignedShiftRight(hash3_initial, 16)) * 0x27d4eb2d);

        // Final mixing step
        hash1 = hash1 ^ (hash1 >> 13);
        hash2 = hash2 ^ (hash2 >> 13);
        hash3 = hash3 ^ (hash3 >> 13);

        // Build UUID parts with good distribution
        const part1 = hash1;
        const part2 = hash2 & 0xffff;
        const part3 = ((hash2 >> 16) & 0x0fff) | 0x4000; // Version 4
        const part4 = (hash3 & 0x3fff) | 0x8000; // Variant bits
        const part5_high = hash3 >> 16;
        const part5_low = hash1 ^ hash2;

        return std.fmt.allocPrint(allocator, "{x:0>8}-{x:0>4}-{x}-{x}-{x:0>4}{x:0>8}", .{ part1, part2, part3, part4, part5_high, part5_low });
    }

    //
    // Type-erased generate for the vtable.
    //
    fn generateErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror![]const u8 {
        _ = io;
        const self: *TestUuidGenerator = @ptrCast(@alignCast(ptr));
        return self.generate(allocator);
    }
};
