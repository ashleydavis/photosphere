const std = @import("std");
const asn1 = @import("asn1.zig");
const big_number = @import("big-number.zig");

//
// RSA as used by node:crypto in the TypeScript code.
// This file has no TypeScript counterpart: TypeScript uses node:crypto (OpenSSL) for RSA.
//
// - publicEncrypt/privateDecrypt use RSAES-OAEP with SHA-1 and MGF1-SHA1 and an empty label, which is what
//   node:crypto's publicEncrypt/privateDecrypt default to when given a KeyObject (RSA_PKCS1_OAEP_PADDING,
//   oaepHash 'sha1'). The TypeScript code never sets padding or oaepHash.
// - The private operation uses the Chinese Remainder Theorem, like OpenSSL.
// - Key generation follows the usual OpenSSL shape: random odd candidates with the two top bits set,
//   a small-prime sieve, Miller-Rabin, public exponent 65537, d = e^-1 mod (p-1)(q-1).
//

//
// Names used from other files (the equivalent of the TypeScript imports).
//
const Limb = big_number.Limb;
const MontgomeryContext = big_number.MontgomeryContext;
const Sha1 = std.crypto.hash.Sha1;

//
// The length of a SHA-1 digest (the OAEP hash).
//
const hash_length = Sha1.digest_length;

//
// The public exponent used for generated keys (same as Node's default).
//
pub const default_public_exponent: u32 = 65537;

//
// The number of Miller-Rabin rounds for each prime candidate. FIPS 186-4 (table C.3) requires 4 rounds for
// 2048-bit primes generated from random candidates; one more is used for margin.
//
const miller_rabin_rounds = 5;

//
// The upper bound (exclusive) of the small primes used to sieve prime candidates.
//
const sieve_limit = 65536;

//
// How far past a random starting point the prime search goes before a new starting point is drawn.
//
const max_search_delta: u32 = 1 << 20;

//
// Errors raised by the RSA operations.
//
pub const RsaError = error{
    // The key components are not a valid RSA key.
    InvalidKey,

    // The message is too long to be encrypted with this key.
    DataTooLarge,

    // The input to a raw RSA operation is not smaller than the modulus.
    DataGreaterThanModulus,

    // The input to a raw RSA operation is longer than the modulus.
    InvalidInputLength,

    // The decrypted block is not valid OAEP.
    OaepDecodingError,
};

//
// An RSA public key with precomputed Montgomery values.
//
pub const PublicKey = struct {
    // The key components (n and e).
    components: asn1.RsaPublicKeyComponents,

    // The modulus as limbs.
    modulus_limbs: []Limb,

    // Montgomery values for the modulus.
    modulus_context: MontgomeryContext,

    //
    // Returns the modulus length in bytes (k in PKCS#1).
    //
    pub fn modulusLength(self: *const PublicKey) usize {
        return self.components.modulus.len;
    }
};

//
// An RSA private key with precomputed Montgomery values for the CRT primes.
//
pub const PrivateKey = struct {
    // The public half of the key.
    public_key: PublicKey,

    // The key components (n, e, d, p, q, dP, dQ, qInv).
    components: asn1.RsaPrivateKeyComponents,

    // The first prime as limbs (half limb count).
    prime1_limbs: []Limb,

    // The second prime as limbs (half limb count).
    prime2_limbs: []Limb,

    // The CRT coefficient qInv as limbs (half limb count).
    coefficient_limbs: []Limb,

    // Montgomery values for p.
    prime1_context: MontgomeryContext,

    // Montgomery values for q.
    prime2_context: MontgomeryContext,
};

//
// Strips leading zero bytes from a big-endian integer (keeping at least one byte).
//
fn stripLeadingZeros(bytes: []const u8) []const u8 {
    var start: usize = 0;
    while (start + 1 < bytes.len and bytes[start] == 0) {
        start += 1;
    }
    return bytes[start..];
}

//
// Creates a public key from its components.
//
pub fn initPublicKey(allocator: std.mem.Allocator, components: asn1.RsaPublicKeyComponents) !PublicKey {
    const modulus = stripLeadingZeros(components.modulus);
    const public_exponent = stripLeadingZeros(components.public_exponent);
    if (modulus.len < 2 or (modulus[modulus.len - 1] & 1) == 0 or (public_exponent.len == 1 and public_exponent[0] < 3)) {
        return error.InvalidKey;
    }
    const modulus_limbs = try big_number.allocFromBytes(allocator, modulus, big_number.limbCountForBytes(modulus.len));
    return PublicKey{
        .components = .{ .modulus = modulus, .public_exponent = public_exponent },
        .modulus_limbs = modulus_limbs,
        .modulus_context = try MontgomeryContext.init(allocator, modulus_limbs),
    };
}

//
// Creates a private key from its components.
//
pub fn initPrivateKey(allocator: std.mem.Allocator, components: asn1.RsaPrivateKeyComponents) !PrivateKey {
    const public_key = try initPublicKey(allocator, .{ .modulus = components.modulus, .public_exponent = components.public_exponent });
    const stripped = asn1.RsaPrivateKeyComponents{
        .modulus = public_key.components.modulus,
        .public_exponent = public_key.components.public_exponent,
        .private_exponent = stripLeadingZeros(components.private_exponent),
        .prime1 = stripLeadingZeros(components.prime1),
        .prime2 = stripLeadingZeros(components.prime2),
        .exponent1 = stripLeadingZeros(components.exponent1),
        .exponent2 = stripLeadingZeros(components.exponent2),
        .coefficient = stripLeadingZeros(components.coefficient),
    };
    const prime1_odd = (stripped.prime1[stripped.prime1.len - 1] & 1) == 1;
    const prime2_odd = (stripped.prime2[stripped.prime2.len - 1] & 1) == 1;
    if (!prime1_odd or !prime2_odd or stripped.prime1.len < 2 or stripped.prime2.len < 2) {
        return error.InvalidKey;
    }
    const half_limb_count = big_number.limbCountForBytes(@max(stripped.prime1.len, stripped.prime2.len));
    if (big_number.limbCountForBytes(stripped.modulus.len) > 2 * half_limb_count or stripped.coefficient.len > stripped.prime1.len) {
        return error.InvalidKey;
    }
    const prime1_limbs = try big_number.allocFromBytes(allocator, stripped.prime1, half_limb_count);
    const prime2_limbs = try big_number.allocFromBytes(allocator, stripped.prime2, half_limb_count);
    return PrivateKey{
        .public_key = public_key,
        .components = stripped,
        .prime1_limbs = prime1_limbs,
        .prime2_limbs = prime2_limbs,
        .coefficient_limbs = try big_number.allocFromBytes(allocator, stripped.coefficient, half_limb_count),
        .prime1_context = try MontgomeryContext.init(allocator, prime1_limbs),
        .prime2_context = try MontgomeryContext.init(allocator, prime2_limbs),
    };
}

//
// Converts an input block of at most k bytes to limbs and checks that it is smaller than the modulus.
//
fn inputToLimbs(allocator: std.mem.Allocator, key: *const PublicKey, input: []const u8) ![]Limb {
    if (input.len > key.modulusLength()) {
        return error.InvalidInputLength;
    }

    //
    // Shorter inputs are treated as numbers with leading zeros, like OpenSSL.
    //
    const input_limbs = try big_number.allocFromBytes(allocator, input, key.modulus_limbs.len);
    if (big_number.compare(input_limbs, key.modulus_limbs) != .lt) {
        return error.DataGreaterThanModulus;
    }
    return input_limbs;
}

//
// The raw RSA public operation: input^e mod n, with input and output being k bytes long.
//
pub fn publicOperation(allocator: std.mem.Allocator, key: *const PublicKey, input: []const u8) ![]u8 {
    const input_limbs = try inputToLimbs(allocator, key, input);
    const result_limbs = try key.modulus_context.pow(allocator, input_limbs, key.components.public_exponent);
    const output = try allocator.alloc(u8, key.modulusLength());
    try big_number.limbsToBytes(output, result_limbs);
    return output;
}

//
// The raw RSA private operation using the CRT: input^d mod n, with input and output being k bytes long.
//
pub fn privateOperation(allocator: std.mem.Allocator, key: *const PrivateKey, input: []const u8) ![]u8 {
    const input_limbs = try inputToLimbs(allocator, &key.public_key, input);
    const ciphertext = big_number.trimLeadingZeroLimbs(input_limbs);
    const prime1_context = &key.prime1_context;
    const half_limb_count = prime1_context.limbCount();

    //
    // m1 = c^dP mod p, m2 = c^dQ mod q.
    //
    const message1 = try prime1_context.pow(allocator, ciphertext, key.components.exponent1);
    const message2 = try key.prime2_context.pow(allocator, ciphertext, key.components.exponent2);

    //
    // h = qInv * (m1 - m2) mod p.
    //
    const message1_montgomery = try prime1_context.toMontgomery(allocator, message1);
    const message2_montgomery = try prime1_context.toMontgomery(allocator, message2);
    const difference = try allocator.alloc(Limb, half_limb_count);
    const borrow = big_number.subtract(difference, message1_montgomery, message2_montgomery);
    if (borrow != 0) {
        _ = big_number.add(difference, difference, key.prime1_limbs);
    }
    const scratch = try allocator.alloc(Limb, half_limb_count + 2);
    const factor = try allocator.alloc(Limb, half_limb_count);
    prime1_context.multiply(factor, difference, key.coefficient_limbs, scratch);

    //
    // m = m2 + h * q.
    //
    const result = try allocator.alloc(Limb, 2 * half_limb_count);
    big_number.multiply(result, factor, key.prime2_limbs);
    const message2_wide = try allocator.alloc(Limb, 2 * half_limb_count);
    @memset(message2_wide, 0);
    @memcpy(message2_wide[0..half_limb_count], message2);
    _ = big_number.add(result, result, message2_wide);

    const output = try allocator.alloc(u8, key.public_key.modulusLength());
    try big_number.limbsToBytes(output, result);
    return output;
}

//
// MGF1 with SHA-1: xors the mask generated from the seed into the target.
//
fn applyMgf1Mask(seed: []const u8, target: []u8) void {
    var counter: u32 = 0;
    var offset: usize = 0;
    while (offset < target.len) : (counter += 1) {
        var hasher = Sha1.init(.{});
        hasher.update(seed);
        var counter_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &counter_bytes, counter, .big);
        hasher.update(&counter_bytes);
        var digest: [hash_length]u8 = undefined;
        hasher.final(&digest);
        const count = @min(hash_length, target.len - offset);
        for (target[offset .. offset + count], digest[0..count]) |*target_byte, mask_byte| {
            target_byte.* ^= mask_byte;
        }
        offset += count;
    }
}

//
// Returns the SHA-1 hash of the empty OAEP label.
//
fn emptyLabelHash() [hash_length]u8 {
    var digest: [hash_length]u8 = undefined;
    Sha1.hash("", &digest, .{});
    return digest;
}

//
// EME-OAEP encoding (RFC 8017 section 7.1.1) with SHA-1, MGF1-SHA1 and an empty label.
//
pub fn oaepEncode(allocator: std.mem.Allocator, io: std.Io, message: []const u8, key_length: usize) ![]u8 {
    if (key_length < 2 * hash_length + 2 or message.len > key_length - 2 * hash_length - 2) {
        return error.DataTooLarge;
    }
    const encoded = try allocator.alloc(u8, key_length);
    @memset(encoded, 0);
    const seed = encoded[1 .. 1 + hash_length];
    const data_block = encoded[1 + hash_length ..];
    const label_hash = emptyLabelHash();
    @memcpy(data_block[0..hash_length], &label_hash);
    data_block[data_block.len - message.len - 1] = 0x01;
    @memcpy(data_block[data_block.len - message.len ..], message);
    io.random(seed);
    applyMgf1Mask(seed, data_block);
    applyMgf1Mask(data_block, seed);
    return encoded;
}

//
// EME-OAEP decoding (RFC 8017 section 7.1.2) with SHA-1, MGF1-SHA1 and an empty label.
//
pub fn oaepDecode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len < 2 * hash_length + 2) {
        return error.OaepDecodingError;
    }
    const block = try allocator.dupe(u8, encoded);
    const seed = block[1 .. 1 + hash_length];
    const data_block = block[1 + hash_length ..];
    applyMgf1Mask(data_block, seed);
    applyMgf1Mask(seed, data_block);
    const label_hash = emptyLabelHash();
    var valid = block[0] == 0 and std.crypto.timing_safe.eql([hash_length]u8, data_block[0..hash_length].*, label_hash);
    var separator_index: usize = hash_length;
    while (separator_index < data_block.len and data_block[separator_index] == 0) {
        separator_index += 1;
    }
    if (separator_index >= data_block.len or data_block[separator_index] != 0x01) {
        valid = false;
    }
    if (!valid) {
        return error.OaepDecodingError;
    }
    return data_block[separator_index + 1 ..];
}

//
// Encrypts a short message with RSAES-OAEP (SHA-1), like node:crypto's publicEncrypt with default options.
//
pub fn publicEncrypt(allocator: std.mem.Allocator, io: std.Io, key: *const PublicKey, message: []const u8) ![]u8 {
    const encoded = try oaepEncode(allocator, io, message, key.modulusLength());
    return publicOperation(allocator, key, encoded);
}

//
// Decrypts a message encrypted with RSAES-OAEP (SHA-1), like node:crypto's privateDecrypt with default options.
//
pub fn privateDecrypt(allocator: std.mem.Allocator, key: *const PrivateKey, ciphertext: []const u8) ![]u8 {
    const encoded = try privateOperation(allocator, key, ciphertext);
    return oaepDecode(allocator, encoded);
}

//
// Returns the odd primes below sieve_limit (sieve of Eratosthenes).
//
fn smallPrimes(allocator: std.mem.Allocator) ![]u32 {
    const composite = try allocator.alloc(bool, sieve_limit);
    @memset(composite, false);
    var primes: std.ArrayList(u32) = .empty;
    var candidate: usize = 3;
    while (candidate < sieve_limit) : (candidate += 2) {
        if (!composite[candidate]) {
            try primes.append(allocator, @intCast(candidate));
            var multiple = candidate * candidate;
            while (multiple < sieve_limit) : (multiple += 2 * candidate) {
                composite[multiple] = true;
            }
        }
    }
    return primes.toOwnedSlice(allocator);
}

//
// Miller-Rabin probabilistic primality test with random bases.
//
fn isProbablePrime(allocator: std.mem.Allocator, io: std.Io, candidate: []const Limb, rounds: usize) !bool {
    const limb_count = candidate.len;
    const context = try MontgomeryContext.init(allocator, candidate);

    //
    // candidate - 1 = odd_part * 2^power.
    //
    const candidate_minus_one = try allocator.dupe(Limb, candidate);
    _ = big_number.subtractSmall(candidate_minus_one, 1);
    const power = big_number.trailingZeroBits(candidate_minus_one);
    const odd_part = try allocator.dupe(Limb, candidate_minus_one);
    big_number.shiftRight(odd_part, power);
    const odd_part_bytes = try big_number.allocMinimalBytes(allocator, odd_part);

    //
    // Montgomery forms of 1 and candidate - 1.
    //
    const one = context.montgomery_one;
    const minus_one = try allocator.alloc(Limb, limb_count);
    _ = big_number.subtract(minus_one, candidate, one);

    const scratch = try allocator.alloc(Limb, 2 * limb_count + 1);
    const base_bytes = try allocator.alloc(u8, limb_count * big_number.limb_bytes);
    const base = try allocator.alloc(Limb, limb_count);
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        //
        // A random base in [2, candidate - 2]: one byte shorter than the candidate, and at least 2.
        //
        const significant_bytes = (big_number.bitLength(candidate) + 7) / 8;
        io.random(base_bytes[0 .. significant_bytes - 1]);
        big_number.limbsFromBytes(base, base_bytes[0 .. significant_bytes - 1]);
        if (big_number.bitLength(base) < 2) {
            base[0] |= 2;
        }

        const base_montgomery = try context.toMontgomery(allocator, base);
        const value = try context.powMontgomery(allocator, base_montgomery, odd_part_bytes);
        if (big_number.compare(value, one) == .eq or big_number.compare(value, minus_one) == .eq) {
            continue;
        }
        var witness_found = true;
        var square_index: usize = 1;
        while (square_index < power) : (square_index += 1) {
            context.square(value, value, scratch);
            if (big_number.compare(value, minus_one) == .eq) {
                witness_found = false;
                break;
            }
            if (big_number.compare(value, one) == .eq) {
                break;
            }
        }
        if (witness_found) {
            return false;
        }
    }
    return true;
}

//
// Generates a random prime of exactly prime_bits bits (with the two top bits set, so that the product of two
// such primes has exactly 2 * prime_bits bits) such that prime - 1 is coprime to the public exponent.
//
fn generatePrime(allocator: std.mem.Allocator, io: std.Io, prime_bits: usize, public_exponent: u32) ![]Limb {
    std.debug.assert(prime_bits % 8 == 0 and prime_bits >= 64);
    const primes = try smallPrimes(allocator);
    const byte_count = prime_bits / 8;
    const limb_count = big_number.limbCountForBytes(byte_count);
    const random_bytes = try allocator.alloc(u8, byte_count);
    const base = try allocator.alloc(Limb, limb_count);
    const candidate = try allocator.alloc(Limb, limb_count);
    const residues = try allocator.alloc(u32, primes.len);

    while (true) {
        io.random(random_bytes);
        random_bytes[0] |= 0xc0;
        random_bytes[byte_count - 1] |= 1;
        big_number.limbsFromBytes(base, random_bytes);
        for (primes, residues) |prime, *residue| {
            residue.* = @intCast(big_number.moduloSmall(base, prime));
        }
        const exponent_residue: u32 = @intCast(big_number.moduloSmall(base, public_exponent));

        var delta: u32 = 0;
        while (delta < max_search_delta) : (delta += 2) {
            var divisible = false;
            for (primes, residues) |prime, residue| {
                if ((residue + delta) % prime == 0) {
                    divisible = true;
                    break;
                }
            }
            if (divisible) {
                continue;
            }

            //
            // prime - 1 must not be a multiple of the public exponent.
            //
            if ((@as(u64, exponent_residue) + delta) % public_exponent == 1) {
                continue;
            }

            @memcpy(candidate, base);
            const carry = big_number.addSmall(candidate, delta);
            if (carry != 0 or big_number.bitLength(candidate) != prime_bits) {
                break;
            }
            if (try isProbablePrime(allocator, io, candidate, miller_rabin_rounds)) {
                return candidate;
            }
        }
    }
}

//
// Extended Euclid for small numbers: returns value^-1 mod modulus (value and modulus coprime).
//
fn inverseModuloSmall(value: u64, modulus: u64) u64 {
    var old_remainder: i128 = @intCast(value % modulus);
    var remainder: i128 = @intCast(modulus);
    var old_coefficient: i128 = 1;
    var coefficient: i128 = 0;
    while (remainder != 0) {
        const quotient = @divFloor(old_remainder, remainder);
        const next_remainder = old_remainder - quotient * remainder;
        old_remainder = remainder;
        remainder = next_remainder;
        const next_coefficient = old_coefficient - quotient * coefficient;
        old_coefficient = coefficient;
        coefficient = next_coefficient;
    }
    return @intCast(@mod(old_coefficient, @as(i128, @intCast(modulus))));
}

//
// Computes e^-1 mod modulus for a small prime e that does not divide the modulus:
// with k = -modulus^-1 mod e, (1 + k * modulus) is divisible by e and the quotient is the inverse.
//
fn inverseOfSmallExponent(allocator: std.mem.Allocator, public_exponent: u32, modulus: []const Limb) ![]Limb {
    const modulus_residue = big_number.moduloSmall(modulus, public_exponent);
    if (modulus_residue == 0) {
        return error.InvalidKey;
    }
    const multiplier = public_exponent - inverseModuloSmall(modulus_residue, public_exponent);
    const value = try allocator.alloc(Limb, modulus.len + 1);
    @memcpy(value[0..modulus.len], modulus);
    value[modulus.len] = 0;
    value[modulus.len] = big_number.multiplySmall(value[0..modulus.len], @intCast(multiplier));
    _ = big_number.addSmall(value, 1);
    const remainder = big_number.divideSmall(value, public_exponent);
    std.debug.assert(remainder == 0);
    std.debug.assert(value[modulus.len] == 0);
    return value[0..modulus.len];
}

//
// Generates an RSA private key with the given modulus size (a multiple of 16 bits) and public exponent.
//
pub fn generateKeyPair(allocator: std.mem.Allocator, io: std.Io, modulus_bits: usize, public_exponent: u32) !PrivateKey {
    const prime_bits = modulus_bits / 2;
    while (true) {
        const prime1 = try generatePrime(allocator, io, prime_bits, public_exponent);
        const prime2 = try generatePrime(allocator, io, prime_bits, public_exponent);
        if (big_number.compare(prime1, prime2) == .eq) {
            continue;
        }
        const half_limb_count = prime1.len;
        const modulus = try allocator.alloc(Limb, 2 * half_limb_count);
        big_number.multiply(modulus, prime1, prime2);
        if (big_number.bitLength(modulus) != modulus_bits) {
            continue;
        }

        const prime1_minus_one = try allocator.dupe(Limb, prime1);
        _ = big_number.subtractSmall(prime1_minus_one, 1);
        const prime2_minus_one = try allocator.dupe(Limb, prime2);
        _ = big_number.subtractSmall(prime2_minus_one, 1);
        const totient = try allocator.alloc(Limb, 2 * half_limb_count);
        big_number.multiply(totient, prime1_minus_one, prime2_minus_one);

        const private_exponent = try inverseOfSmallExponent(allocator, public_exponent, totient);
        const exponent1 = try inverseOfSmallExponent(allocator, public_exponent, prime1_minus_one);
        const exponent2 = try inverseOfSmallExponent(allocator, public_exponent, prime2_minus_one);

        //
        // qInv = q^(p - 2) mod p (p is prime).
        //
        const prime1_context = try MontgomeryContext.init(allocator, prime1);
        const prime1_minus_two = try allocator.dupe(Limb, prime1);
        _ = big_number.subtractSmall(prime1_minus_two, 2);
        const coefficient = try prime1_context.pow(allocator, prime2, try big_number.allocMinimalBytes(allocator, prime1_minus_two));

        var exponent_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &exponent_bytes, public_exponent, .big);
        return initPrivateKey(allocator, .{
            .modulus = try big_number.allocMinimalBytes(allocator, modulus),
            .public_exponent = try allocator.dupe(u8, stripLeadingZeros(&exponent_bytes)),
            .private_exponent = try big_number.allocMinimalBytes(allocator, private_exponent),
            .prime1 = try big_number.allocMinimalBytes(allocator, prime1),
            .prime2 = try big_number.allocMinimalBytes(allocator, prime2),
            .exponent1 = try big_number.allocMinimalBytes(allocator, exponent1),
            .exponent2 = try big_number.allocMinimalBytes(allocator, exponent2),
            .coefficient = try big_number.allocMinimalBytes(allocator, coefficient),
        });
    }
}
