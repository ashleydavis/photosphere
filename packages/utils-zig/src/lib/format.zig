const std = @import("std");

//
// The unit names used by formatFileSize.
//
const sizes = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };

//
// Formats file size in bytes to human readable string.
// (Zig: the number is printed with `{d}`, the shortest round trip decimal, like JavaScript's number to string
// conversion for these values.)
//
pub fn formatFileSize(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
    if (bytes == 0) {
        return allocator.dupe(u8, "0 B");
    }
    const k: f64 = 1024;
    const bytesFloat: f64 = @floatFromInt(bytes);
    const unitIndex: usize = @intFromFloat(@floor(@log(bytesFloat) / @log(k)));
    const value = bytesFloat / std.math.pow(f64, k, @floatFromInt(unitIndex));
    const rounded = @floor(value * 100 + 0.5) / 100;
    return std.fmt.allocPrint(allocator, "{d} {s}", .{ rounded, sizes[unitIndex] });
}
