const std = @import("std");
const encryption = @import("encryption-zig");

const big_number = encryption.big_number;
const Limb = big_number.Limb;

//
// Converts a u128 to limbs.
//
fn limbsFromInt(allocator: std.mem.Allocator, value: u128, limb_count: usize) ![]Limb {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, value, .big);
    return big_number.allocFromBytes(allocator, &bytes, limb_count);
}

//
// Converts limbs to a u128.
//
fn intFromLimbs(limbs: []const Limb) !u128 {
    var bytes: [16]u8 = undefined;
    try big_number.limbsToBytes(&bytes, limbs);
    return std.mem.readInt(u128, &bytes, .big);
}

//
// Computes base^exponent mod modulus with plain integer arithmetic.
//
fn referencePow(base: u128, exponent: u128, modulus: u128) u128 {
    var result: u256 = 1;
    var power: u256 = base % modulus;
    var remaining = exponent;
    while (remaining > 0) : (remaining >>= 1) {
        if ((remaining & 1) == 1) {
            result = (result * power) % modulus;
        }
        power = (power * power) % modulus;
    }
    return @intCast(result);
}

test "limbsFromBytes and limbsToBytes round-trip and detect overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bytes = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const limbs = try big_number.allocFromBytes(allocator, &bytes, big_number.limbCountForBytes(bytes.len));
    var output: [11]u8 = undefined;
    try big_number.limbsToBytes(&output, limbs);
    try std.testing.expectEqualSlices(u8, &bytes, &output);
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.Overflow, big_number.limbsToBytes(&small, limbs));
    try std.testing.expectEqualSlices(u8, &bytes, try big_number.allocMinimalBytes(allocator, limbs));
    try std.testing.expectEqual(@as(usize, 81), big_number.bitLength(limbs));
}

test "add, subtract, multiply and small operations match integer arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const left_value: u128 = 0x1234_5678_9abc_def0_1122_3344;
    const right_value: u128 = 0xffff_ffff_ffff_0000_1111;
    const limb_count = big_number.limbCountForBytes(16);
    const left = try limbsFromInt(allocator, left_value, limb_count);
    const right = try limbsFromInt(allocator, right_value, limb_count);
    const sum = try allocator.alloc(Limb, limb_count);
    try std.testing.expectEqual(@as(Limb, 0), big_number.add(sum, left, right));
    try std.testing.expectEqual(left_value + right_value, try intFromLimbs(sum));
    try std.testing.expectEqual(@as(Limb, 0), big_number.subtract(sum, left, right));
    try std.testing.expectEqual(left_value - right_value, try intFromLimbs(sum));
    try std.testing.expectEqual(@as(Limb, 1), big_number.subtract(sum, right, left));

    const small_left = try limbsFromInt(allocator, 0xffff_ffff_ffff, limb_count / 2);
    const small_right = try limbsFromInt(allocator, 0x1_0000_0001, limb_count / 2);
    const product = try allocator.alloc(Limb, limb_count);
    big_number.multiply(product, small_left, small_right);
    try std.testing.expectEqual(@as(u128, 0xffff_ffff_ffff) * 0x1_0000_0001, try intFromLimbs(product));

    const value = try limbsFromInt(allocator, left_value, limb_count);
    try std.testing.expectEqual(@as(Limb, @intCast(left_value % 65537)), big_number.moduloSmall(value, 65537));
    const remainder = big_number.divideSmall(value, 65537);
    try std.testing.expectEqual(@as(Limb, @intCast(left_value % 65537)), remainder);
    try std.testing.expectEqual(left_value / 65537, try intFromLimbs(value));
    _ = big_number.multiplySmall(value, 65537);
    _ = big_number.addSmall(value, remainder);
    try std.testing.expectEqual(left_value, try intFromLimbs(value));
    _ = big_number.subtractSmall(value, 0x44);
    try std.testing.expectEqual(left_value - 0x44, try intFromLimbs(value));

    big_number.shiftRight(value, 12);
    try std.testing.expectEqual((left_value - 0x44) >> 12, try intFromLimbs(value));
    try std.testing.expectEqual(@as(usize, 4), big_number.trailingZeroBits(try limbsFromInt(allocator, 0x30, limb_count)));
    try std.testing.expectEqual(@as(usize, 1), big_number.trimLeadingZeroLimbs(try limbsFromInt(allocator, 5, limb_count)).len);
}

test "MontgomeryContext.pow matches integer modular exponentiation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const moduli = [_]u128{ 0xffff_ffff_ffff_ffc5, 0x1_0000_0000_0000_0000_0000_0003, 0xd, 0xffff_fffb };
    for (moduli) |modulus_value| {
        const limb_count = big_number.limbCountForBytes(16);
        const modulus = try limbsFromInt(allocator, modulus_value, limb_count);
        const context = try big_number.MontgomeryContext.init(allocator, modulus);
        const bases = [_]u128{ 0, 1, 2, 12345, modulus_value - 1, 0xdead_beef_cafe_babe_1234 };
        const exponents = [_]u128{ 0, 1, 2, 65537, 0x1234_5678_9abc_def1 };
        for (bases) |base_value| {
            for (exponents) |exponent_value| {
                var exponent_bytes: [16]u8 = undefined;
                std.mem.writeInt(u128, &exponent_bytes, exponent_value, .big);
                const base = try limbsFromInt(allocator, base_value, limb_count);
                const result = try context.pow(allocator, base, &exponent_bytes);
                try std.testing.expectEqual(referencePow(base_value, exponent_value, modulus_value), try intFromLimbs(result));
            }
        }
    }
}

test "MontgomeryContext.toMontgomery reduces values twice as long as the modulus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const modulus_value: u128 = 0xffff_fffb;
    const limb_count = big_number.limbCountForBytes(8);
    const modulus = try limbsFromInt(allocator, modulus_value, limb_count);
    const context = try big_number.MontgomeryContext.init(allocator, modulus);
    const value_limbs = try limbsFromInt(allocator, 0xffff_ffff_ffff_ffff_1234_5678, 2 * limb_count);
    const montgomery = try context.toMontgomery(allocator, value_limbs);
    const plain = try context.fromMontgomery(allocator, montgomery);
    try std.testing.expectEqual(@as(u128, 0xffff_ffff_ffff_ffff_1234_5678) % modulus_value, try intFromLimbs(plain));
}
