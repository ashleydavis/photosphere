const std = @import("std");
const builtin = @import("builtin");

//
// Multi-precision unsigned integer arithmetic used by rsa.zig.
// This file has no TypeScript counterpart: TypeScript uses node:crypto (OpenSSL) for RSA.
//
// Numbers are stored as little-endian slices of limbs (limbs[0] is the least significant).
// Modular exponentiation uses Montgomery multiplication (CIOS) with a fixed 4-bit window.
//

//
// The type of one limb of a big number. The LLVM backend (release builds) is fastest with 64-bit limbs.
// The self-hosted Debug backend lowers 128-bit multiplication poorly, so 32-bit limbs are about 3.5 times
// faster there (this keeps RSA-4096 key generation reasonable in plain Debug builds).
//
pub const Limb = switch (builtin.zig_backend) {
    .stage2_llvm => u64,
    else => u32,
};

//
// The type used to hold the product of two limbs.
//
const DoubleLimb = std.meta.Int(.unsigned, 2 * @bitSizeOf(Limb));

//
// The type used to hold a shift amount within a limb.
//
const LimbShift = std.math.Log2Int(Limb);

//
// The number of bits in one limb.
//
pub const limb_bits = @bitSizeOf(Limb);

//
// The number of bytes in one limb.
//
pub const limb_bytes = @sizeOf(Limb);

//
// Returns the number of limbs needed to hold a number of the given byte length.
//
pub fn limbCountForBytes(byte_count: usize) usize {
    return (byte_count + limb_bytes - 1) / limb_bytes;
}

//
// Converts a big-endian byte string into little-endian limbs. The limbs slice must be large enough;
// unused high limbs are set to zero.
//
pub fn limbsFromBytes(limbs: []Limb, bytes: []const u8) void {
    @memset(limbs, 0);
    var byte_index: usize = 0;
    while (byte_index < bytes.len) : (byte_index += 1) {
        const position = bytes.len - 1 - byte_index;
        const limb_index = byte_index / limb_bytes;
        const shift: LimbShift = @intCast((byte_index % limb_bytes) * 8);
        std.debug.assert(limb_index < limbs.len or bytes[position] == 0);
        if (limb_index < limbs.len) {
            limbs[limb_index] |= @as(Limb, bytes[position]) << shift;
        }
    }
}

//
// Converts little-endian limbs into a fixed-length big-endian byte string.
// Returns error.Overflow when the number does not fit.
//
pub fn limbsToBytes(bytes: []u8, limbs: []const Limb) error{Overflow}!void {
    @memset(bytes, 0);
    var limb_index: usize = 0;
    while (limb_index < limbs.len) : (limb_index += 1) {
        var shift_index: usize = 0;
        while (shift_index < limb_bytes) : (shift_index += 1) {
            const shift: LimbShift = @intCast(shift_index * 8);
            const byte_value: u8 = @truncate(limbs[limb_index] >> shift);
            const byte_offset = limb_index * limb_bytes + shift_index;
            if (byte_offset < bytes.len) {
                bytes[bytes.len - 1 - byte_offset] = byte_value;
            }
            else if (byte_value != 0) {
                return error.Overflow;
            }
        }
    }
}

//
// Allocates a big number from big-endian bytes with exactly `limb_count` limbs.
//
pub fn allocFromBytes(allocator: std.mem.Allocator, bytes: []const u8, limb_count: usize) ![]Limb {
    const limbs = try allocator.alloc(Limb, limb_count);
    limbsFromBytes(limbs, bytes);
    return limbs;
}

//
// Converts a big number to the shortest big-endian byte string (at least one byte).
//
pub fn allocMinimalBytes(allocator: std.mem.Allocator, limbs: []const Limb) ![]u8 {
    const full = try allocator.alloc(u8, limbs.len * limb_bytes);
    limbsToBytes(full, limbs) catch unreachable;
    var start: usize = 0;
    while (start + 1 < full.len and full[start] == 0) {
        start += 1;
    }
    return full[start..];
}

//
// Returns the number of significant bits in a big number.
//
pub fn bitLength(limbs: []const Limb) usize {
    var limb_index = limbs.len;
    while (limb_index > 0) {
        limb_index -= 1;
        if (limbs[limb_index] != 0) {
            return limb_index * limb_bits + (limb_bits - @clz(limbs[limb_index]));
        }
    }
    return 0;
}

//
// Returns true when a big number is zero.
//
pub fn isZero(limbs: []const Limb) bool {
    for (limbs) |limb| {
        if (limb != 0) {
            return false;
        }
    }
    return true;
}

//
// Compares two big numbers of the same limb count.
//
pub fn compare(left: []const Limb, right: []const Limb) std.math.Order {
    std.debug.assert(left.len == right.len);
    var limb_index = left.len;
    while (limb_index > 0) {
        limb_index -= 1;
        if (left[limb_index] != right[limb_index]) {
            if (left[limb_index] < right[limb_index]) {
                return .lt;
            }
            return .gt;
        }
    }
    return .eq;
}

//
// Computes result = left + right over equal-length slices and returns the carry out.
// The result may alias either operand.
//
pub fn add(result: []Limb, left: []const Limb, right: []const Limb) Limb {
    std.debug.assert(left.len == right.len and result.len == left.len);
    var carry: Limb = 0;
    for (result, left, right) |*result_limb, left_limb, right_limb| {
        const sum: DoubleLimb = @as(DoubleLimb, left_limb) + right_limb + carry;
        result_limb.* = @truncate(sum);
        carry = @truncate(sum >> limb_bits);
    }
    return carry;
}

//
// Computes result = left - right over equal-length slices and returns the borrow out.
// The result may alias either operand.
//
pub fn subtract(result: []Limb, left: []const Limb, right: []const Limb) Limb {
    std.debug.assert(left.len == right.len and result.len == left.len);
    var borrow: Limb = 0;
    for (result, left, right) |*result_limb, left_limb, right_limb| {
        const first = @subWithOverflow(left_limb, right_limb);
        const second = @subWithOverflow(first[0], borrow);
        result_limb.* = second[0];
        borrow = @as(Limb, first[1]) + second[1];
    }
    return borrow;
}

//
// Adds a small value to a big number in place and returns the carry out.
//
pub fn addSmall(limbs: []Limb, value: Limb) Limb {
    var carry = value;
    for (limbs) |*limb| {
        if (carry == 0) {
            break;
        }
        const sum = @addWithOverflow(limb.*, carry);
        limb.* = sum[0];
        carry = sum[1];
    }
    return carry;
}

//
// Subtracts a small value from a big number in place and returns the borrow out.
//
pub fn subtractSmall(limbs: []Limb, value: Limb) Limb {
    var borrow = value;
    for (limbs) |*limb| {
        if (borrow == 0) {
            break;
        }
        const difference = @subWithOverflow(limb.*, borrow);
        limb.* = difference[0];
        borrow = difference[1];
    }
    return borrow;
}

//
// Multiplies a big number by a small value in place and returns the carry out.
//
pub fn multiplySmall(limbs: []Limb, value: Limb) Limb {
    var carry: Limb = 0;
    for (limbs) |*limb| {
        const product: DoubleLimb = @as(DoubleLimb, limb.*) * value + carry;
        limb.* = @truncate(product);
        carry = @truncate(product >> limb_bits);
    }
    return carry;
}

//
// Divides a big number by a small value in place and returns the remainder.
//
pub fn divideSmall(limbs: []Limb, divisor: Limb) Limb {
    var remainder: DoubleLimb = 0;
    var limb_index = limbs.len;
    while (limb_index > 0) {
        limb_index -= 1;
        const dividend: DoubleLimb = (remainder << limb_bits) | limbs[limb_index];
        limbs[limb_index] = @truncate(dividend / divisor);
        remainder = dividend % divisor;
    }
    return @truncate(remainder);
}

//
// Returns a big number modulo a small value.
//
pub fn moduloSmall(limbs: []const Limb, divisor: Limb) Limb {
    var remainder: DoubleLimb = 0;
    var limb_index = limbs.len;
    while (limb_index > 0) {
        limb_index -= 1;
        remainder = ((remainder << limb_bits) | limbs[limb_index]) % divisor;
    }
    return @truncate(remainder);
}

//
// Shifts a big number right in place by a number of bits.
//
pub fn shiftRight(limbs: []Limb, bit_count: usize) void {
    const limb_shift = bit_count / limb_bits;
    const bit_shift: LimbShift = @intCast(bit_count % limb_bits);
    var limb_index: usize = 0;
    while (limb_index < limbs.len) : (limb_index += 1) {
        const source_index = limb_index + limb_shift;
        var value: Limb = 0;
        if (source_index < limbs.len) {
            value = limbs[source_index] >> bit_shift;
            if (bit_shift != 0 and source_index + 1 < limbs.len) {
                value |= limbs[source_index + 1] << @intCast(limb_bits - @as(usize, bit_shift));
            }
        }
        limbs[limb_index] = value;
    }
}

//
// Returns the number of trailing zero bits of a non-zero big number.
//
pub fn trailingZeroBits(limbs: []const Limb) usize {
    for (limbs, 0..) |limb, limb_index| {
        if (limb != 0) {
            return limb_index * limb_bits + @ctz(limb);
        }
    }
    return limbs.len * limb_bits;
}

//
// Returns the limbs without leading (most significant) zero limbs, keeping at least one limb.
//
pub fn trimLeadingZeroLimbs(limbs: []const Limb) []const Limb {
    var length = limbs.len;
    while (length > 1 and limbs[length - 1] == 0) {
        length -= 1;
    }
    return limbs[0..length];
}

//
// Computes result = left * right (schoolbook). The result must have left.len + right.len limbs and must
// not alias the operands.
//
pub fn multiply(result: []Limb, left: []const Limb, right: []const Limb) void {
    std.debug.assert(result.len == left.len + right.len);
    @memset(result, 0);
    for (right, 0..) |right_limb, right_index| {
        var carry: Limb = 0;
        for (left, 0..) |left_limb, left_index| {
            const product: DoubleLimb = @as(DoubleLimb, left_limb) * right_limb + result[left_index + right_index] + carry;
            result[left_index + right_index] = @truncate(product);
            carry = @truncate(product >> limb_bits);
        }
        result[left.len + right_index] = carry;
    }
}

//
// Precomputed values for Montgomery arithmetic modulo an odd number.
//
pub const MontgomeryContext = struct {
    // The odd modulus.
    modulus: []const Limb,

    // -modulus^-1 mod 2^limb_bits.
    modulus_inverse: Limb,

    // R mod modulus, where R = 2^(limb_bits * limb count) (the Montgomery form of 1).
    montgomery_one: []Limb,

    // R^2 mod modulus (used to convert numbers into Montgomery form).
    r_squared: []Limb,

    //
    // Creates a context for an odd modulus (the slice is referenced, not copied).
    //
    pub fn init(allocator: std.mem.Allocator, modulus: []const Limb) !MontgomeryContext {
        std.debug.assert(modulus.len > 0 and (modulus[0] & 1) == 1);

        //
        // Newton iteration for the inverse of the lowest limb modulo 2^limb_bits.
        //
        var inverse: Limb = 1;
        var iteration: usize = 0;
        while (iteration < 6) : (iteration += 1) {
            inverse = inverse *% (2 -% modulus[0] *% inverse);
        }

        //
        // Computes R mod m and R^2 mod m by repeated doubling of 1.
        //
        const limb_count = modulus.len;
        const value = try allocator.alloc(Limb, limb_count);
        @memset(value, 0);
        value[0] = 1;
        const montgomery_one = try allocator.alloc(Limb, limb_count);
        var doubling: usize = 0;
        while (doubling < 2 * limb_count * limb_bits) : (doubling += 1) {
            const carry = add(value, value, value);
            if (carry != 0 or compare(value, modulus) != .lt) {
                _ = subtract(value, value, modulus);
            }
            if (doubling + 1 == limb_count * limb_bits) {
                @memcpy(montgomery_one, value);
            }
        }

        return MontgomeryContext{
            .modulus = modulus,
            .modulus_inverse = 0 -% inverse,
            .montgomery_one = montgomery_one,
            .r_squared = value,
        };
    }

    //
    // Returns the number of limbs in the modulus.
    //
    pub fn limbCount(self: *const MontgomeryContext) usize {
        return self.modulus.len;
    }

    //
    // Computes result = left * right * R^-1 mod m. Both operands must be less than the modulus
    // (or their product less than m * R). The result may alias the operands. The scratch slice must
    // hold limb count + 2 limbs.
    //
    pub fn multiply(self: *const MontgomeryContext, result: []Limb, left: []const Limb, right: []const Limb, scratch: []Limb) void {
        //
        // This is the hot loop of every RSA operation; bounds checks are disabled here for speed in Debug builds.
        //
        @setRuntimeSafety(false);

        const limb_count = self.modulus.len;
        const modulus = self.modulus;
        const accumulator = scratch[0 .. limb_count + 2];
        @memset(accumulator, 0);
        for (0..limb_count) |outer_index| {
            const right_limb = right[outer_index];
            var carry: Limb = 0;
            for (0..limb_count) |inner_index| {
                const product: DoubleLimb = @as(DoubleLimb, left[inner_index]) * right_limb + accumulator[inner_index] + carry;
                accumulator[inner_index] = @truncate(product);
                carry = @truncate(product >> limb_bits);
            }
            var sum: DoubleLimb = @as(DoubleLimb, accumulator[limb_count]) + carry;
            accumulator[limb_count] = @truncate(sum);
            accumulator[limb_count + 1] = @truncate(sum >> limb_bits);

            const factor = accumulator[0] *% self.modulus_inverse;
            var reduction: DoubleLimb = @as(DoubleLimb, factor) * modulus[0] + accumulator[0];
            carry = @truncate(reduction >> limb_bits);
            for (1..limb_count) |inner_index| {
                reduction = @as(DoubleLimb, factor) * modulus[inner_index] + accumulator[inner_index] + carry;
                accumulator[inner_index - 1] = @truncate(reduction);
                carry = @truncate(reduction >> limb_bits);
            }
            sum = @as(DoubleLimb, accumulator[limb_count]) + carry;
            accumulator[limb_count - 1] = @truncate(sum);
            accumulator[limb_count] = accumulator[limb_count + 1] + @as(Limb, @truncate(sum >> limb_bits));
        }

        if (accumulator[limb_count] != 0 or compare(accumulator[0..limb_count], modulus) != .lt) {
            _ = subtract(result, accumulator[0..limb_count], modulus);
        }
        else {
            @memcpy(result, accumulator[0..limb_count]);
        }
    }

    //
    // Computes result = value^2 * R^-1 mod m (value less than the modulus). Squaring computes each cross product
    // once and then does a separate Montgomery reduction, which is about 25% cheaper than multiply(). The result may
    // alias the operand. The scratch slice must hold 2 * limb count + 1 limbs.
    //
    pub fn square(self: *const MontgomeryContext, result: []Limb, value: []const Limb, scratch: []Limb) void {
        //
        // Hot loop: bounds checks are disabled here for speed in Debug builds.
        //
        @setRuntimeSafety(false);

        const limb_count = self.modulus.len;
        const modulus = self.modulus;
        const product = scratch[0 .. 2 * limb_count + 1];
        @memset(product, 0);

        //
        // Cross products value[i] * value[j] for i < j.
        //
        for (0..limb_count) |outer_index| {
            const outer_limb = value[outer_index];
            var carry: Limb = 0;
            for (outer_index + 1..limb_count) |inner_index| {
                const partial: DoubleLimb = @as(DoubleLimb, outer_limb) * value[inner_index] + product[outer_index + inner_index] + carry;
                product[outer_index + inner_index] = @truncate(partial);
                carry = @truncate(partial >> limb_bits);
            }
            product[outer_index + limb_count] = carry;
        }

        //
        // Doubles the cross products and adds the squares value[i]^2.
        //
        var shifted_out: Limb = 0;
        for (product[0 .. 2 * limb_count]) |*limb| {
            const next_shifted_out = limb.* >> (limb_bits - 1);
            limb.* = (limb.* << 1) | shifted_out;
            shifted_out = next_shifted_out;
        }
        var carry: Limb = 0;
        for (0..limb_count) |limb_index| {
            const square_value: DoubleLimb = @as(DoubleLimb, value[limb_index]) * value[limb_index];
            const low_sum: DoubleLimb = @as(DoubleLimb, product[2 * limb_index]) + @as(Limb, @truncate(square_value)) + carry;
            product[2 * limb_index] = @truncate(low_sum);
            const high_sum: DoubleLimb = @as(DoubleLimb, product[2 * limb_index + 1]) + @as(Limb, @truncate(square_value >> limb_bits)) + (low_sum >> limb_bits);
            product[2 * limb_index + 1] = @truncate(high_sum);
            carry = @truncate(high_sum >> limb_bits);
        }
        product[2 * limb_count] = carry;

        //
        // Montgomery reduction of the double-length product.
        //
        for (0..limb_count) |outer_index| {
            const factor = product[outer_index] *% self.modulus_inverse;
            var reduction_carry: Limb = 0;
            for (0..limb_count) |inner_index| {
                const partial: DoubleLimb = @as(DoubleLimb, factor) * modulus[inner_index] + product[outer_index + inner_index] + reduction_carry;
                product[outer_index + inner_index] = @truncate(partial);
                reduction_carry = @truncate(partial >> limb_bits);
            }
            var carry_index = outer_index + limb_count;
            while (reduction_carry != 0 and carry_index <= 2 * limb_count) : (carry_index += 1) {
                const sum: DoubleLimb = @as(DoubleLimb, product[carry_index]) + reduction_carry;
                product[carry_index] = @truncate(sum);
                reduction_carry = @truncate(sum >> limb_bits);
            }
        }

        const reduced = product[limb_count .. 2 * limb_count];
        if (product[2 * limb_count] != 0 or compare(reduced, modulus) != .lt) {
            _ = subtract(result, reduced, modulus);
        }
        else {
            @memcpy(result, reduced);
        }
    }

    //
    // Converts a number of up to 2 * limb count limbs into Montgomery form (value * R mod m).
    //
    pub fn toMontgomery(self: *const MontgomeryContext, allocator: std.mem.Allocator, value: []const Limb) ![]Limb {
        const limb_count = self.modulus.len;
        std.debug.assert(value.len <= 2 * limb_count);
        const scratch = try allocator.alloc(Limb, limb_count + 2);
        const low = try allocator.alloc(Limb, limb_count);
        const high = try allocator.alloc(Limb, limb_count);
        @memset(low, 0);
        @memset(high, 0);
        const low_count = @min(value.len, limb_count);
        @memcpy(low[0..low_count], value[0..low_count]);
        if (value.len > limb_count) {
            @memcpy(high[0 .. value.len - limb_count], value[limb_count..]);
        }

        //
        // value * R = high * R^2 + low * R (mod m).
        //
        const result = try allocator.alloc(Limb, limb_count);
        self.multiply(low, low, self.r_squared, scratch);
        self.multiply(high, high, self.r_squared, scratch);
        self.multiply(high, high, self.r_squared, scratch);
        const carry = add(result, low, high);
        if (carry != 0 or compare(result, self.modulus) != .lt) {
            _ = subtract(result, result, self.modulus);
        }
        return result;
    }

    //
    // Converts a number out of Montgomery form.
    //
    pub fn fromMontgomery(self: *const MontgomeryContext, allocator: std.mem.Allocator, value: []const Limb) ![]Limb {
        const limb_count = self.modulus.len;
        const scratch = try allocator.alloc(Limb, limb_count + 2);
        const unit = try allocator.alloc(Limb, limb_count);
        @memset(unit, 0);
        unit[0] = 1;
        const result = try allocator.alloc(Limb, limb_count);
        self.multiply(result, value, unit, scratch);
        return result;
    }

    //
    // Computes base^exponent in Montgomery form, where base is in Montgomery form and the exponent is a
    // big-endian byte string. Uses a fixed 4-bit window.
    //
    pub fn powMontgomery(self: *const MontgomeryContext, allocator: std.mem.Allocator, base: []const Limb, exponent: []const u8) ![]Limb {
        const limb_count = self.modulus.len;
        const scratch = try allocator.alloc(Limb, 2 * limb_count + 1);
        const table = try allocator.alloc(Limb, 16 * limb_count);
        @memcpy(table[0..limb_count], self.montgomery_one);
        @memcpy(table[limb_count .. 2 * limb_count], base);
        var table_index: usize = 2;
        while (table_index < 16) : (table_index += 1) {
            self.multiply(
                table[table_index * limb_count .. (table_index + 1) * limb_count],
                table[(table_index - 1) * limb_count .. table_index * limb_count],
                base,
                scratch,
            );
        }

        const result = try allocator.alloc(Limb, limb_count);
        @memcpy(result, self.montgomery_one);
        var started = false;
        for (exponent) |exponent_byte| {
            const nibbles = [2]usize{ exponent_byte >> 4, exponent_byte & 0x0f };
            for (nibbles) |nibble| {
                if (started) {
                    var square_index: usize = 0;
                    while (square_index < 4) : (square_index += 1) {
                        self.square(result, result, scratch);
                    }
                }
                if (started or nibble != 0) {
                    self.multiply(result, result, table[nibble * limb_count .. (nibble + 1) * limb_count], scratch);
                    started = true;
                }
            }
        }
        return result;
    }

    //
    // Computes base^exponent mod m for an ordinary (non Montgomery) base of up to 2 * limb count limbs.
    //
    pub fn pow(self: *const MontgomeryContext, allocator: std.mem.Allocator, base: []const Limb, exponent: []const u8) ![]Limb {
        const base_montgomery = try self.toMontgomery(allocator, base);
        const result_montgomery = try self.powMontgomery(allocator, base_montgomery, exponent);
        return self.fromMontgomery(allocator, result_montgomery);
    }
};
