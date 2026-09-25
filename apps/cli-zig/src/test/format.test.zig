const std = @import("std");
const cli = @import("cli-zig");
const helpers = @import("test-helpers.zig");
const formatBytes = cli.format.formatBytes;

//
// Formats with the default options (binary units, 2 decimals).
//
fn format(allocator: std.mem.Allocator, bytes: f64) ![]const u8 {
    return formatBytes(allocator, bytes, cli.format.defaultFormatBytesOptions);
}

//
// Formats with decimal units.
//
fn formatDecimal(allocator: std.mem.Allocator, bytes: f64) ![]const u8 {
    return formatBytes(allocator, bytes, .{ .binary = false, .decimals = 2 });
}

test "should format 0 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("0 Bytes", try format(arena.allocator(), 0));
}

test "should format bytes under 1 KiB" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("100 Bytes", try format(arena.allocator(), 100));
    try std.testing.expectEqualStrings("1,023 Bytes", try format(arena.allocator(), 1023));
}

test "should format exactly 1 KiB" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("1 KiB", try format(arena.allocator(), 1024));
}

test "should format KiB values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("1.5 KiB", try format(allocator, 1536));
    try std.testing.expectEqualStrings("2 KiB", try format(allocator, 2048));
    try std.testing.expectEqualStrings("10 KiB", try format(allocator, 10240));
    try std.testing.expectEqualStrings("100 KiB", try format(allocator, 102400));
}

test "should format MiB values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("1 MiB", try format(allocator, 1048576));
    try std.testing.expectEqualStrings("1.5 MiB", try format(allocator, 1572864));
    try std.testing.expectEqualStrings("10 MiB", try format(allocator, 10485760));
    try std.testing.expectEqualStrings("100 MiB", try format(allocator, 104857600));
}

test "should format GiB values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("1 GiB", try format(allocator, 1073741824));
    try std.testing.expectEqualStrings("1.5 GiB", try format(allocator, 1610612736));
    try std.testing.expectEqualStrings("10 GiB", try format(allocator, 10737418240));
    try std.testing.expectEqualStrings("100 GiB", try format(allocator, 107374182400));
}

test "should format TiB values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("1 TiB", try format(allocator, 1099511627776));
    try std.testing.expectEqualStrings("1.5 TiB", try format(allocator, 1649267441664));
}

test "should handle intelligent decimal places" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("100 MiB", try format(allocator, 104857600));
    try std.testing.expectEqualStrings("100 GiB", try format(allocator, 107374182400));
    try std.testing.expectEqualStrings("12 MiB", try format(allocator, 12582912));
    try std.testing.expectEqualStrings("12.5 MiB", try format(allocator, 13107200));
    try std.testing.expectEqualStrings("5 MiB", try format(allocator, 5242880));
    try std.testing.expectEqualStrings("5.5 MiB", try format(allocator, 5767168));
    try std.testing.expectEqualStrings("2.25 MiB", try format(allocator, 2359296));
}

test "should format exactly 1 KB" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("1 KB", try formatDecimal(arena.allocator(), 1000));
}

test "should format KB values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("1.5 KB", try formatDecimal(allocator, 1500));
    try std.testing.expectEqualStrings("10 KB", try formatDecimal(allocator, 10000));
    try std.testing.expectEqualStrings("100 KB", try formatDecimal(allocator, 100000));
}

test "should format MB values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("1 MB", try formatDecimal(allocator, 1000000));
    try std.testing.expectEqualStrings("1.5 MB", try formatDecimal(allocator, 1500000));
    try std.testing.expectEqualStrings("10 MB", try formatDecimal(allocator, 10000000));
}

test "should format GB values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("1 GB", try formatDecimal(allocator, 1000000000));
    try std.testing.expectEqualStrings("1.5 GB", try formatDecimal(allocator, 1500000000));
}

// Not ported: "should format with German locale", "should format with French locale" (only en-US is ported).

test "should respect custom decimal places for small values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("2.25 MiB", try formatBytes(allocator, 2359296, .{ .binary = true, .decimals = 3 }));
    try std.testing.expectEqualStrings("2.3 MiB", try formatBytes(allocator, 2411724, .{ .binary = true, .decimals = 3 }));
    try std.testing.expectEqualStrings("2.2 MiB", try formatBytes(allocator, 2306867, .{ .binary = true, .decimals = 3 }));
}

test "formatBytes matches the TypeScript output for every fixture value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try helpers.loadFixture(allocator, "format.json");
    for (fixture.array.items) |formatCase| {
        const bytes: f64 = @floatFromInt(helpers.intField(formatCase, "bytes"));
        const options: cli.format.IFormatBytesOptions = .{
            .binary = helpers.boolField(formatCase, "binary"),
            .decimals = @intCast(helpers.intField(formatCase, "decimals")),
        };
        const output = try formatBytes(allocator, bytes, options);
        std.testing.expectEqualStrings(helpers.stringField(formatCase, "output"), output) catch |err| {
            std.debug.print("bytes={d}\n", .{bytes});
            return err;
        };
    }
}

test "toLocaleString rounds half away from zero and groups thousands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("10.3", try cli.format.toLocaleString(allocator, 10.25, 1));
    try std.testing.expectEqualStrings("1.01", try cli.format.toLocaleString(allocator, 1.005, 2));
    try std.testing.expectEqualStrings("1.13", try cli.format.toLocaleString(allocator, 1.125, 2));
    try std.testing.expectEqualStrings("1,234,567", try cli.format.toLocaleString(allocator, 1234567, 0));
    try std.testing.expectEqualStrings("10", try cli.format.toLocaleString(allocator, 9.999, 2));
    try std.testing.expectEqualStrings("0", try cli.format.toLocaleString(allocator, 0, 2));
}
