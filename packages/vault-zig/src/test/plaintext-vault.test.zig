const std = @import("std");
const vault_zig = @import("vault-zig");
const PlaintextVault = vault_zig.plaintext_vault.PlaintextVault;
const ISecret = vault_zig.vault.ISecret;

//
// A unique temporary directory for one test, so that tests are fully isolated from one another
// and from the real ~/.config/photosphere/vault.
//
const TempDir = struct {
    // The directory created by std.testing.tmpDir.
    tmp_dir: std.testing.TmpDir,

    // The path of the directory relative to the working directory.
    path: []const u8,

    //
    // Removes the temporary directory and all its contents after a test.
    //
    fn remove(self: *TempDir) void {
        self.tmp_dir.cleanup();
    }
};

//
// Creates a unique temporary directory for a test.
//
fn makeTempDir(allocator: std.mem.Allocator) !TempDir {
    const tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_dir.sub_path});
    return .{ .tmp_dir = tmp_dir, .path = path };
}

//
// Returns the Unix permission bits of a file or directory.
//
fn permissionBits(io: std.Io, path: []const u8) !u32 {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    return @intCast(@intFromEnum(stat.permissions) & 0o777);
}

//
// Orders secrets by name.
//
fn secretNameLessThan(context: void, left: ISecret, right: ISecret) bool {
    _ = context;
    return std.mem.order(u8, left.name, right.name) == .lt;
}

test "get: returns undefined for a secret that does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();
    var vault = PlaintextVault.init(temp_dir.path);

    const result = try vault.get(allocator, std.testing.io, "nonexistent");
    try std.testing.expect(result == null);
}

test "get: returns the secret after it has been set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();
    var vault = PlaintextVault.init(temp_dir.path);

    const secret: ISecret = .{ .name = "my-key", .type = "api-key", .value = "abc123" };
    try vault.set(allocator, io, secret);
    const result = (try vault.get(allocator, io, "my-key")).?;
    try std.testing.expectEqualStrings(secret.name, result.name);
    try std.testing.expectEqualStrings(secret.type, result.type);
    try std.testing.expectEqualStrings(secret.value, result.value);
}

test "get: returns the latest value when a secret is overwritten" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();
    var vault = PlaintextVault.init(temp_dir.path);

    try vault.set(allocator, io, .{ .name = "token", .type = "api-key", .value = "old-value" });
    try vault.set(allocator, io, .{ .name = "token", .type = "api-key", .value = "new-value" });
    const result = (try vault.get(allocator, io, "token")).?;
    try std.testing.expectEqualStrings("new-value", result.value);
}

test "set: creates the vault directory if it does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();

    const nestedDir = try std.fs.path.join(allocator, &.{ temp_dir.path, "nested", "vault" });
    var nestedVault = PlaintextVault.init(nestedDir);
    try nestedVault.set(allocator, io, .{ .name = "key", .type = "password", .value = "secret" });
    const result = (try nestedVault.get(allocator, io, "key")).?;
    try std.testing.expectEqualStrings("secret", result.value);
}

test "set: stores the name, type, and value of the secret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();
    var vault = PlaintextVault.init(temp_dir.path);

    try vault.set(allocator, io, .{ .name = "db-pass", .type = "password", .value = "hunter2" });
    const result = (try vault.get(allocator, io, "db-pass")).?;
    try std.testing.expectEqualStrings("db-pass", result.name);
    try std.testing.expectEqualStrings("password", result.type);
    try std.testing.expectEqualStrings("hunter2", result.value);
}

test "set: supports arbitrary type strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();
    var vault = PlaintextVault.init(temp_dir.path);

    try vault.set(allocator, io, .{ .name = "cred", .type = "s3-credentials", .value = "{\"accessKeyId\":\"AKIA...\",\"secretAccessKey\":\"xyz\"}" });
    const result = (try vault.get(allocator, io, "cred")).?;
    try std.testing.expectEqualStrings("s3-credentials", result.type);
}

test "set: supports a key pair secret with both private and public key in the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();
    var vault = PlaintextVault.init(temp_dir.path);

    const keyPairValue = "{\"privateKey\":\"-----BEGIN PRIVATE KEY-----\",\"publicKey\":\"-----BEGIN PUBLIC KEY-----\"}";
    try vault.set(allocator, io, .{ .name = "my-keypair", .type = "key-pair", .value = keyPairValue });
    const result = (try vault.get(allocator, io, "my-keypair")).?;
    try std.testing.expectEqualStrings("key-pair", result.type);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, result.value, .{});
    try std.testing.expectEqualStrings("-----BEGIN PRIVATE KEY-----", parsed.object.get("privateKey").?.string);
    try std.testing.expectEqualStrings("-----BEGIN PUBLIC KEY-----", parsed.object.get("publicKey").?.string);
}

test "list: returns an empty array when the vault is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();
    var vault = PlaintextVault.init(temp_dir.path);

    const secrets = try vault.list(allocator, std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), secrets.len);
}

test "list: returns an empty array when the vault directory does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();

    var emptyVault = PlaintextVault.init(try std.fs.path.join(allocator, &.{ temp_dir.path, "does-not-exist" }));
    const secrets = try emptyVault.list(allocator, std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), secrets.len);
}

test "list: returns all stored secrets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();
    var vault = PlaintextVault.init(temp_dir.path);

    try vault.set(allocator, io, .{ .name = "beta", .type = "api-key", .value = "bbb" });
    try vault.set(allocator, io, .{ .name = "alpha", .type = "password", .value = "aaa" });
    const secrets = try vault.list(allocator, io);
    try std.testing.expectEqual(@as(usize, 2), secrets.len);

    // Entries are returned in file name order (like Node's sorted fs.readdir).
    try std.testing.expectEqualStrings("alpha", secrets[0].name);
    try std.testing.expectEqualStrings("beta", secrets[1].name);
}

// Not ported: "does not include deleted secrets" (PlaintextVault.delete is not ported: not used by psi replicate or psi verify).

test "list: ignores files without the .json extension" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();
    var vault = PlaintextVault.init(temp_dir.path);

    try vault.set(allocator, io, .{ .name = "real", .type = "api-key", .value = "val" });

    // Write a stray file that should be ignored.
    try temp_dir.tmp_dir.dir.writeFile(io, .{ .sub_path = "noise.txt", .data = "ignore me" });
    const secrets = try vault.list(allocator, io);
    try std.testing.expectEqual(@as(usize, 1), secrets.len);
}

// Not ported: "delete" tests (PlaintextVault.delete is not ported: not used by psi replicate or psi verify).

test "secret names with special characters: handles names containing spaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();
    var vault = PlaintextVault.init(temp_dir.path);

    try vault.set(allocator, io, .{ .name = "my secret", .type = "password", .value = "spaced" });
    const result = (try vault.get(allocator, io, "my secret")).?;
    try std.testing.expectEqualStrings("spaced", result.value);
}

test "secret names with special characters: handles names containing slashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();
    var vault = PlaintextVault.init(temp_dir.path);

    try vault.set(allocator, io, .{ .name = "org/repo/token", .type = "api-key", .value = "tok" });
    const result = (try vault.get(allocator, io, "org/repo/token")).?;
    try std.testing.expectEqualStrings("tok", result.value);
}

test "secret names with special characters: handles names containing unicode characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();
    var vault = PlaintextVault.init(temp_dir.path);

    try vault.set(allocator, io, .{ .name = "clé-secrète", .type = "password", .value = "motdepasse" });
    const result = (try vault.get(allocator, io, "clé-secrète")).?;
    try std.testing.expectEqualStrings("motdepasse", result.value);
}

test "secret names with special characters: handles multiple specially named secrets without collision" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();
    var vault = PlaintextVault.init(temp_dir.path);

    try vault.set(allocator, io, .{ .name = "a/b", .type = "password", .value = "slash" });
    try vault.set(allocator, io, .{ .name = "a%2Fb", .type = "password", .value = "percent" });
    const slash = (try vault.get(allocator, io, "a/b")).?;
    const percent = (try vault.get(allocator, io, "a%2Fb")).?;
    try std.testing.expectEqualStrings("slash", slash.value);
    try std.testing.expectEqualStrings("percent", percent.value);
}

test "file permissions: secret file is created with owner-only permissions (0o600)" {
    if (@import("builtin").os.tag == .windows) {
        return;
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();
    var vault = PlaintextVault.init(temp_dir.path);

    try vault.set(allocator, io, .{ .name = "perm-test", .type = "password", .value = "s3cr3t" });
    const filePath = try std.fs.path.join(allocator, &.{ temp_dir.path, "perm-test.json" });
    try std.testing.expectEqual(@as(u32, 0o600), try permissionBits(io, filePath));
}

test "file permissions: vault directory is created with owner-only permissions (0o700)" {
    if (@import("builtin").os.tag == .windows) {
        return;
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();

    const newVaultDir = try std.fs.path.join(allocator, &.{ temp_dir.path, "new-vault" });
    var newVault = PlaintextVault.init(newVaultDir);
    try newVault.set(allocator, io, .{ .name = "key", .type = "password", .value = "val" });
    try std.testing.expectEqual(@as(u32, 0o700), try permissionBits(io, newVaultDir));
}

// Not ported: "exists" tests (PlaintextVault.exists is not ported: not used by psi replicate or psi verify).

test "encodeSecretName percent-encodes like encodeURIComponent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const encode = vault_zig.plaintext_vault.encodeSecretName;

    try std.testing.expectEqualStrings("default%3As3", try encode(allocator, "default:s3"));
    try std.testing.expectEqualStrings("a%252Fb", try encode(allocator, "a%2Fb"));
    try std.testing.expectEqualStrings("cl%C3%A9", try encode(allocator, "clé"));
    try std.testing.expectEqualStrings("AZaz09-_.!~*'()", try encode(allocator, "AZaz09-_.!~*'()"));
    try std.testing.expectEqualStrings("%20%2F%3F%23%26%3D%2B%24%2C%40%5B%5D", try encode(allocator, " /?#&=+$,@[]"));
}

test "decodeSecretName reverses encodeSecretName and rejects malformed input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const decode = vault_zig.plaintext_vault.decodeSecretName;

    try std.testing.expectEqualStrings("default:s3", try decode(allocator, "default%3As3"));
    try std.testing.expectEqualStrings("clé", try decode(allocator, "cl%C3%A9"));
    try std.testing.expectEqualStrings("a%2Fb", try decode(allocator, "a%252Fb"));
    try std.testing.expectError(error.Thrown, decode(allocator, "bad%2"));
    try std.testing.expectEqualStrings("URI malformed", @import("utils-zig").errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, decode(allocator, "bad%zz"));
    try std.testing.expectError(error.Thrown, decode(allocator, "bad%C3"));
}

test "DEFAULT_VAULT_DIR is ~/.config/photosphere/vault" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const process_env = @import("node-utils-zig").process_env;

    var environ_map = std.process.Environ.Map.init(allocator);
    try environ_map.put("HOME", "/home/tester");
    try environ_map.put("USERPROFILE", "/home/tester");
    process_env.setEnvironMap(&environ_map);
    defer process_env.setEnvironMap(null);

    const expected = try std.fs.path.join(allocator, &.{ "/home/tester", ".config", "photosphere", "vault" });
    try std.testing.expectEqualStrings(expected, try vault_zig.plaintext_vault.DEFAULT_VAULT_DIR(allocator));
}

test "vault() exposes the PlaintextVault through the IVault interface" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();
    var plaintext_vault = PlaintextVault.init(temp_dir.path);
    const vault = plaintext_vault.vault();

    try vault.set(allocator, io, .{ .name = "via-interface", .type = "plain", .value = "v" });
    const result = (try vault.get(allocator, io, "via-interface")).?;
    try std.testing.expectEqualStrings("v", result.value);
    const secrets = try vault.list(allocator, io);
    try std.testing.expectEqual(@as(usize, 1), secrets.len);
}

//
// Loads the secrets that generate.ts wrote to ts-vault/.
//
fn loadFixtureSecrets(allocator: std.mem.Allocator, io: std.Io) ![]ISecret {
    const json = try std.Io.Dir.cwd().readFileAlloc(io, "src/test/fixtures/secrets.json", allocator, .unlimited);
    return std.json.parseFromSliceLeaky([]ISecret, allocator, json, .{});
}

test "interop: Zig reads vault entries written by TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const secrets = try loadFixtureSecrets(allocator, io);
    var vault = PlaintextVault.init("src/test/fixtures/ts-vault");

    for (secrets) |expected| {
        const result = (try vault.get(allocator, io, expected.name)).?;
        try std.testing.expectEqualStrings(expected.name, result.name);
        try std.testing.expectEqualStrings(expected.type, result.type);
        try std.testing.expectEqualStrings(expected.value, result.value);
    }

    const listed = try vault.list(allocator, io);
    try std.testing.expectEqual(secrets.len, listed.len);
    const sorted_expected = try allocator.dupe(ISecret, secrets);
    std.mem.sort(ISecret, sorted_expected, {}, secretNameLessThan);
    std.mem.sort(ISecret, listed, {}, secretNameLessThan);
    for (sorted_expected, listed) |expected, actual| {
        try std.testing.expectEqualStrings(expected.name, actual.name);
        try std.testing.expectEqualStrings(expected.value, actual.value);
    }
}

test "interop: Zig writes vault files byte-identical to TypeScript (so TypeScript reads them)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const secrets = try loadFixtureSecrets(allocator, io);
    var temp_dir = try makeTempDir(allocator);
    defer temp_dir.remove();
    var vault = PlaintextVault.init(temp_dir.path);

    for (secrets) |secret| {
        try vault.set(allocator, io, secret);
    }

    var fixture_dir = try std.Io.Dir.cwd().openDir(io, "src/test/fixtures/ts-vault", .{ .iterate = true });
    defer fixture_dir.close(io);
    var iterator = fixture_dir.iterate();
    var file_count: usize = 0;
    while (try iterator.next(io)) |entry| {
        const expected = try fixture_dir.readFileAlloc(io, entry.name, allocator, .unlimited);
        const actual = try temp_dir.tmp_dir.dir.readFileAlloc(io, entry.name, allocator, .unlimited);
        try std.testing.expectEqualStrings(expected, actual);
        file_count += 1;
    }
    try std.testing.expectEqual(secrets.len, file_count);
}
