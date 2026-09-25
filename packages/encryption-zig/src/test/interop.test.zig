const std = @import("std");
const encryption = @import("encryption-zig");
const helpers = @import("test-helpers.zig");

//
// Golden interop tests between the TypeScript encryption package and this port, in both directions.
// The TypeScript side of the fixtures is written by fixtures/generate.ts; the Zig output is checked by
// fixtures/verify-zig-output.ts, which this file runs with bun.
//

const crypto = encryption.node_crypto;
const key_utils = encryption.key_utils;
const encrypt_buffer = encryption.encrypt_buffer;
const encrypt_stream = encryption.encrypt_stream;
const IPrivateKeyMap = encryption.encryption_types.IPrivateKeyMap;

//
// The plaintext sizes covered by the fixtures.
//
const sizes = [_]usize{ 0, 1, 15, 16, 17, 1048576 };

//
// The size whose plaintext and legacy ciphertext are not stored in the fixtures.
//
const large_size = 1048576;

//
// The directory (relative to the package) that the Zig output for TypeScript is written to.
//
const output_dir = "tmp/zig-output";

//
// Builds a key map with "default" and the hash of the key.
//
fn buildKeyMap(allocator: std.mem.Allocator, privateKey: *const crypto.PrivateKey) !IPrivateKeyMap {
    const publicKey = crypto.createPublicKeyFromPrivateKey(privateKey);
    const keyHashHex = try allocator.dupe(u8, &std.fmt.bytesToHex(try key_utils.hashPublicKey(allocator, publicKey), .lower));
    var keyMap: IPrivateKeyMap = .empty;
    try keyMap.put(allocator, "default", privateKey);
    try keyMap.put(allocator, keyHashHex, privateKey);
    return keyMap;
}

//
// Decrypts data through a decryption stream.
//
fn decryptThroughStream(allocator: std.mem.Allocator, keyMap: *const IPrivateKeyMap, encrypted: []const u8) ![]u8 {
    const input = try allocator.create(std.Io.Reader);
    input.* = std.Io.Reader.fixed(encrypted);
    const decryptionStream = try encrypt_stream.createDecryptionStream(allocator, keyMap, input);
    return helpers.readAll(allocator, decryptionStream.reader());
}

//
// Encrypts data through an encryption stream.
//
fn encryptThroughStream(allocator: std.mem.Allocator, publicKey: *const crypto.PublicKey, plain: []const u8) ![]u8 {
    const input = try allocator.create(std.Io.Reader);
    input.* = std.Io.Reader.fixed(plain);
    const encryptionStream = try encrypt_stream.createEncryptionStream(allocator, std.testing.io, publicKey, input);
    return helpers.readAll(allocator, encryptionStream.reader());
}

//
// Writes one file into the output directory.
//
fn writeOutput(allocator: std.mem.Allocator, fileName: []const u8, data: []const u8) !void {
    const outputPath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, fileName });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = outputPath, .data = data });
}

test "Zig decrypts every TypeScript fixture (new format, legacy format and stream output)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const privateKey = try crypto.createPrivateKey(allocator, try helpers.readFixture(allocator, "ts-private.pem"));
    const keyMap = try buildKeyMap(allocator, privateKey);
    var hashOnlyMap = try keyMap.clone(allocator);
    _ = hashOnlyMap.swapRemove("default");

    for (sizes) |size| {
        const plain = try helpers.makePlaintext(allocator, size);
        const newFormat = try helpers.readFixture(allocator, try std.fmt.allocPrint(allocator, "new-{d}.bin", .{size}));
        try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptBuffer(allocator, newFormat, &keyMap));
        try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptNewFormat(allocator, newFormat, &hashOnlyMap));
        try std.testing.expectEqualSlices(u8, plain, try decryptThroughStream(allocator, &keyMap, newFormat));

        var legacy: []const u8 = newFormat[44..];
        if (size != large_size) {
            const storedPlain = try helpers.readFixture(allocator, try std.fmt.allocPrint(allocator, "plain-{d}.bin", .{size}));
            try std.testing.expectEqualSlices(u8, plain, storedPlain);
            legacy = try helpers.readFixture(allocator, try std.fmt.allocPrint(allocator, "legacy-{d}.bin", .{size}));

            const streamed = try helpers.readFixture(allocator, try std.fmt.allocPrint(allocator, "stream-{d}.bin", .{size}));
            try std.testing.expectEqual(encrypt_stream.computeEncryptedLength(size), streamed.len);
            try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptBuffer(allocator, streamed, &keyMap));
            try std.testing.expectEqualSlices(u8, plain, try decryptThroughStream(allocator, &keyMap, streamed));
        }
        try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptBuffer(allocator, legacy, &keyMap));
        try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptLegacy(allocator, legacy, privateKey));
        try std.testing.expectEqualSlices(u8, plain, try decryptThroughStream(allocator, &keyMap, legacy));
    }
}

test "Zig encrypts and decrypts its own output for every size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const privateKey = try crypto.createPrivateKey(allocator, try helpers.readFixture(allocator, "ts-private.pem"));
    const publicKey = try crypto.createPublicKey(allocator, try helpers.readFixture(allocator, "ts-public.pem"));
    const keyMap = try buildKeyMap(allocator, privateKey);
    for (sizes) |size| {
        const plain = try helpers.makePlaintext(allocator, size);
        const encrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, publicKey, plain);
        try std.testing.expectEqual(encrypt_stream.computeEncryptedLength(size), encrypted.len);
        try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptBuffer(allocator, encrypted, &keyMap));
        try std.testing.expectEqualSlices(u8, plain, try decryptThroughStream(allocator, &keyMap, encrypted));

        const streamed = try encryptThroughStream(allocator, publicKey, plain);
        try std.testing.expectEqual(encrypt_stream.computeEncryptedLength(size), streamed.len);
        try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptBuffer(allocator, streamed, &keyMap));
        try std.testing.expectEqualSlices(u8, plain, try decryptThroughStream(allocator, &keyMap, streamed));
    }
}

test "TypeScript decrypts Zig output and loads Zig PEM keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(io, output_dir);
    try cwd.createDirPath(io, output_dir);
    defer cwd.deleteTree(io, output_dir) catch {};

    //
    // A key pair generated by Zig, exported like the CLI does.
    //
    const keyPair = try key_utils.generateKeyPair(allocator, io);
    const privateKeyPem = try crypto.exportPrivateKey(allocator, keyPair.privateKey, .pem);
    const publicKeyPem = try key_utils.exportPublicKeyToPem(allocator, keyPair.publicKey);
    try writeOutput(allocator, "zig-private.pem", privateKeyPem);
    try writeOutput(allocator, "zig-public.pem", publicKeyPem);
    try writeOutput(allocator, "zig-public-hash.hex", &std.fmt.bytesToHex(try key_utils.hashPublicKey(allocator, keyPair.publicKey), .lower));

    const tsPublicKey = try crypto.createPublicKey(allocator, try helpers.readFixture(allocator, "ts-public.pem"));
    try writeOutput(allocator, "ts-public-hash-by-zig.hex", &std.fmt.bytesToHex(try key_utils.hashPublicKey(allocator, tsPublicKey), .lower));

    for (sizes) |size| {
        const plain = try helpers.makePlaintext(allocator, size);
        try writeOutput(allocator, try std.fmt.allocPrint(allocator, "plain-{d}.bin", .{size}), plain);
        const zigEncrypted = try encrypt_buffer.encryptBuffer(allocator, io, keyPair.publicKey, plain);
        try writeOutput(allocator, try std.fmt.allocPrint(allocator, "zig-new-{d}.bin", .{size}), zigEncrypted);
        const zigTsEncrypted = try encrypt_buffer.encryptBuffer(allocator, io, tsPublicKey, plain);
        try writeOutput(allocator, try std.fmt.allocPrint(allocator, "zig-ts-new-{d}.bin", .{size}), zigTsEncrypted);
        const zigStream = try encryptThroughStream(allocator, keyPair.publicKey, plain);
        try writeOutput(allocator, try std.fmt.allocPrint(allocator, "zig-stream-{d}.bin", .{size}), zigStream);
    }

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "bun", "run", "src/test/fixtures/verify-zig-output.ts", output_dir },
    }) catch |err| {

        // The TypeScript side of this interop test needs Bun; skip it where Bun cannot be spawned.
        if (err == error.FileNotFound) {
            return error.SkipZigTest;
        }
        std.debug.print("Failed to run bun (it must be on PATH): {s}\n", .{@errorName(err)});
        return err;
    };
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("verify-zig-output.ts failed:\n{s}\n{s}\n", .{ result.stdout, result.stderr });
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqualStrings("OK\n", result.stdout);
}
