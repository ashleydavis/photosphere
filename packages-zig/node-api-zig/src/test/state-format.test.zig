const std = @import("std");
const node_api = @import("node-api-zig");
const state_format = node_api.state_format;

//
// A state with a value in every section, built from the document it would be read from.
//
fn fullState(allocator: std.mem.Allocator) !state_format.IStateFile {
    const document = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"desktop":{"last_folder":"/photos","dev_tools_open":true},"searches":{"recent":["beach","dogs"]},"gallery":{"sort":"date","row_height":240},"news":{"shown_news_ids":["a","b"],"last_shown_update_version":"1.2.3","feed":[{"id":"n1","message":"Hello","color":"success","duration":5000,"link":"https://example.com"}]},"ui":{"sidebar-collapsed":true}}
    , .{});
    return state_format.yamlToStateFile(allocator, document);
}

//
// The state a reader falls back to when there is no file is every section's own defaults.
//
test "defaultStateFile is every section's own defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const state = try state_format.defaultStateFile(allocator);

    try std.testing.expect(state.desktop.lastFolder == null);
    try std.testing.expect(state.searches.recentSearches == null);
    try std.testing.expect(state.gallery.sort == null);
    try std.testing.expectEqual(@as(usize, 0), state.news.shownNewsIds.len);
    try std.testing.expectEqual(@as(usize, 0), state.news.feed.len);
}









//
// An allocator that refuses the first allocation asked of it and passes every later one to the allocator it wraps, so the
// code under test runs out of memory once and can still build whatever it returns afterwards.
//
const FailFirstAllocator = struct {
    // The allocator every allocation after the first goes to.
    inner: std.mem.Allocator,

    // Whether the first allocation has been refused yet.
    refused: bool = false,

    //
    // Gets the allocator interface.
    //
    fn allocator(self: *FailFirstAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
                .free = std.mem.Allocator.noFree,
            },
        };
    }

    //
    // Refuses the first allocation and passes on the rest.
    //
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, returnAddress: usize) ?[*]u8 {
        const self: *FailFirstAllocator = @ptrCast(@alignCast(context));
        if (!self.refused) {
            self.refused = true;
            return null;
        }
        return self.inner.rawAlloc(length, alignment, returnAddress);
    }
};

