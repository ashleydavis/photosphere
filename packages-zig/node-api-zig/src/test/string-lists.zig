const std = @import("std");

//
// Sorts a list of strings in place (for comparing lists whose order depends on task completion order).
//
pub fn sortStrings(strings: [][]const u8) void {
    std.mem.sort([]const u8, strings, {}, struct {
        fn lessThan(context: void, left: []const u8, right: []const u8) bool {
            _ = context;
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
}
