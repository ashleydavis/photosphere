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
    try std.testing.expectEqual(@as(usize, 0), state.ui.count());
}

test "buildStateYaml produces text parseStateYamlChecked reads back as the state it was given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const original = try fullState(allocator);

    const text = try state_format.buildStateYaml(allocator, original);
    const parsed = try state_format.parseStateYamlChecked(allocator, text);

    try std.testing.expect(!parsed.malformed);
    try std.testing.expectEqualStrings(
        \\desktop:
        \\  last_folder: /photos
        \\  dev_tools_open: true
        \\searches:
        \\  recent:
        \\    - beach
        \\    - dogs
        \\gallery:
        \\  sort: date
        \\  row_height: 240
        \\news:
        \\  shown_news_ids:
        \\    - a
        \\    - b
        \\  last_shown_update_version: 1.2.3
        \\  feed:
        \\    - id: n1
        \\      message: Hello
        \\      color: success
        \\      duration: 5000
        \\      link: https://example.com
        \\ui:
        \\  sidebar-collapsed: true
        \\
    , text);
    try std.testing.expectEqualStrings("/photos", parsed.state.desktop.lastFolder.?);
    try std.testing.expectEqualStrings("beach", parsed.state.searches.recentSearches.?[0]);
    try std.testing.expectEqualStrings("date", parsed.state.gallery.sort.?);
    try std.testing.expectEqualStrings("1.2.3", parsed.state.news.lastShownUpdateVersion.?);
    try std.testing.expectEqualStrings("n1", parsed.state.news.feed[0].id);
    try std.testing.expectEqual(@as(usize, 1), parsed.state.ui.count());
}

test "parseStateYamlChecked reports text that will not parse as malformed, with what the parser said" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try state_format.parseStateYamlChecked(allocator, "desktop:\n  last_folder: /photos\n   bad indentation: [");

    try std.testing.expect(parsed.malformed);
    try std.testing.expect(std.mem.startsWith(u8, parsed.parseError.?, "YAMLException: "));
    try std.testing.expect(parsed.document == null);
    try std.testing.expect(parsed.state.desktop.lastFolder == null);
}

test "parseStateYamlChecked reports the document of text that parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try state_format.parseStateYamlChecked(allocator, "gallery:\n  sort: name\n");

    try std.testing.expect(!parsed.malformed);
    try std.testing.expect(parsed.parseError == null);
    try std.testing.expectEqualStrings("name", parsed.state.gallery.sort.?);
    try std.testing.expectEqualStrings("name", parsed.document.?.object.get("gallery").?.object.get("sort").?.string);
}

test "parseStateYamlChecked: an empty file and a file that is not a mapping have no document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const empty = try state_format.parseStateYamlChecked(allocator, "");
    const list = try state_format.parseStateYamlChecked(allocator, "- 1\n- 2\n");

    try std.testing.expect(!empty.malformed);
    try std.testing.expect(empty.document == null);
    try std.testing.expect(!list.malformed);
    try std.testing.expect(list.document == null);
}
