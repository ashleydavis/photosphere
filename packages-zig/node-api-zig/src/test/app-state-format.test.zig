const std = @import("std");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const app_state_format = node_api.app_state_format;
const IAppState = app_state_format.IAppState;

//
// Parses JSON text into the value a YAML document holds (what the TypeScript tests write as an object literal).
//
fn parse(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// A value as compact JSON (what the TypeScript tests compare with toEqual).
//
fn toText(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{
        .emit_null_optional_fields = false,
    });
}

//
// The pure conversions between the on-disk document and the in-memory flat state.
//
test "yamlToAppState converts every snake_case key to its camelCase field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const state = try app_state_format.yamlToAppState(allocator, try parse(allocator,
        \\{"desktop":{"last_folder":"/folder","last_download_folder":"/downloads","dev_tools_open":true},
        \\ "searches":{"recent":["cats"]},
        \\ "gallery":{"sort":"name","row_height":240},
        \\ "ui":{"sidebar-collapsed-databases":true}}
    ));

    try std.testing.expectEqualStrings("/folder", state.lastFolder.?);
    try std.testing.expectEqualStrings("/downloads", state.lastDownloadFolder.?);
    try std.testing.expect(state.devToolsOpen.?);
    try std.testing.expectEqual(@as(usize, 1), state.recentSearches.?.len);
    try std.testing.expectEqualStrings("cats", state.recentSearches.?[0]);
    try std.testing.expectEqualStrings("name", state.gallerySort.?);
    try std.testing.expectEqual(@as(i64, 240), state.galleryRowHeight.?.integer);
    try std.testing.expectEqual(@as(usize, 1), state.ui.?.count());
    try std.testing.expect(state.ui.?.get("sidebar-collapsed-databases").?.bool);
}

//
// An absent key stays absent so the interface can apply its own default to it, and a document that is not an object
// reads as nothing stored at all.
//
test "yamlToAppState leaves absent keys absent and reads a document that is not an object as empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const documents = [_][]const u8{ "{}", "[1,2]", "\"text\"", "null" };
    for (documents) |text| {
        const state = try app_state_format.yamlToAppState(allocator, try parse(allocator, text));
        try std.testing.expect(state.lastFolder == null);
        try std.testing.expect(state.lastDownloadFolder == null);
        try std.testing.expect(state.devToolsOpen == null);
        try std.testing.expect(state.recentSearches == null);
        try std.testing.expect(state.gallerySort == null);
        try std.testing.expect(state.galleryRowHeight == null);
        try std.testing.expect(state.ui == null);
    }

    const missing = try app_state_format.yamlToAppState(allocator, null);
    try std.testing.expect(missing.lastFolder == null);
    try std.testing.expect(missing.ui == null);
}

//
// A hand-edited file can hold the wrong type for a field. That field reads as absent, the rest of its section is read,
// and a list of searches keeps only its strings.
//
test "yamlToAppState drops a field of the wrong type and keeps the strings of a list of searches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const state = try app_state_format.yamlToAppState(allocator, try parse(allocator,
        \\{"desktop":{"last_folder":7,"last_download_folder":"/downloads","dev_tools_open":"yes"},
        \\ "searches":{"recent":["cats",3,null,"dogs"]},
        \\ "gallery":{"sort":false,"row_height":"tall"},
        \\ "ui":{"collapsed":true,"nested":{"a":1},"mixed":["a",1],"nothing":null}}
    ));

    try std.testing.expect(state.lastFolder == null);
    try std.testing.expectEqualStrings("/downloads", state.lastDownloadFolder.?);
    try std.testing.expect(state.devToolsOpen == null);
    try std.testing.expectEqual(@as(usize, 2), state.recentSearches.?.len);
    try std.testing.expectEqualStrings("cats", state.recentSearches.?[0]);
    try std.testing.expectEqualStrings("dogs", state.recentSearches.?[1]);
    try std.testing.expect(state.gallerySort == null);
    try std.testing.expect(state.galleryRowHeight == null);
    try std.testing.expectEqual(@as(usize, 1), state.ui.?.count());
    try std.testing.expect(state.ui.?.get("collapsed").?.bool);
}

//
// A section that is a list, a string or null reads as an empty section.
//
test "yamlToAppState reads a section that is not an object as empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const state = try app_state_format.yamlToAppState(allocator, try parse(allocator,
        \\{"desktop":["x"],"searches":"cats","gallery":null,"ui":[1]}
    ));

    try std.testing.expect(state.lastFolder == null);
    try std.testing.expect(state.recentSearches == null);
    try std.testing.expect(state.gallerySort == null);
    try std.testing.expect(state.ui == null);
}

//
// The state a document was read from writes back as the same state.
//
test "appStateToYaml round trips the whole state through the document and back unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ui: app_state_format.IUiSection = .empty;
    try ui.put(allocator, "sidebar-collapsed-databases", .{
        .bool = true,
    });
    const original: IAppState = .{
        .lastFolder = "/folder",
        .recentSearches = &.{"dogs"},
        .gallerySort = "date",
        .ui = ui,
    };

    const document = try app_state_format.appStateToYaml(allocator, original, .{
        .object = .empty,
    });
    try std.testing.expectEqualStrings(
        \\{"desktop":{"last_folder":"/folder"},"searches":{"recent":["dogs"]},"gallery":{"sort":"date"},"ui":{"sidebar-collapsed-databases":true}}
    , try toText(allocator, document));

    const reread = try app_state_format.yamlToAppState(allocator, document);
    try std.testing.expectEqualStrings("/folder", reread.lastFolder.?);
    try std.testing.expectEqualStrings("dogs", reread.recentSearches.?[0]);
    try std.testing.expectEqualStrings("date", reread.gallerySort.?);
    try std.testing.expect(reread.ui.?.get("sidebar-collapsed-databases").?.bool);
}

//
// Every declared field is written under its snake_case name in its own section.
//
test "appStateToYaml writes each field under its snake_case key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try app_state_format.appStateToYaml(allocator, .{
        .lastFolder = "/folder",
        .lastDownloadFolder = "/downloads",
        .devToolsOpen = true,
        .recentSearches = &.{ "cats", "dogs" },
        .gallerySort = "name",
        .galleryRowHeight = .{
            .integer = 240,
        },
    }, .{
        .object = .empty,
    });

    try std.testing.expectEqualStrings(
        \\{"desktop":{"last_folder":"/folder","last_download_folder":"/downloads","dev_tools_open":true},"searches":{"recent":["cats","dogs"]},"gallery":{"sort":"name","row_height":240}}
    , try toText(allocator, document));
}

//
// A file never carries an empty section.
//
test "appStateToYaml writes no empty section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try app_state_format.appStateToYaml(allocator, .{}, .{
        .object = .empty,
    });

    try std.testing.expectEqualStrings("{}", try toText(allocator, document));
}

//
// A document that is not an object is replaced rather than merged into.
//
test "appStateToYaml starts from an empty document when the document is not an object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try app_state_format.appStateToYaml(allocator, .{
        .gallerySort = "name",
    }, .{
        .string = "not a document",
    });

    try std.testing.expectEqualStrings("{\"gallery\":{\"sort\":\"name\"}}", try toText(allocator, document));
}

//
// A cleared field is removed from its section, and a section left empty goes with it.
//
test "appStateToYaml removes a section that has been emptied rather than leaving it behind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const emptied = try app_state_format.appStateToYaml(allocator, .{}, try parse(allocator,
        \\{"desktop":{"last_folder":"/folder"}}
    ));
    try std.testing.expectEqualStrings("{}", try toText(allocator, emptied));

    const partly = try app_state_format.appStateToYaml(allocator, .{
        .lastDownloadFolder = "/downloads",
    }, try parse(allocator,
        \\{"desktop":{"last_folder":"/folder","last_download_folder":"/downloads"}}
    ));
    try std.testing.expectEqualStrings("{\"desktop\":{\"last_download_folder\":\"/downloads\"}}", try toText(allocator, partly));
}

//
// The news state is in the same document and appears nowhere in the flat view, so a write that rebuilt the document from
// the flat view alone would delete what the user had already been shown.
//
test "appStateToYaml leaves the news state alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try app_state_format.appStateToYaml(allocator, .{
        .gallerySort = "name",
    }, try parse(allocator,
        \\{"news":{"shown_news_ids":["release-1"]}}
    ));

    try std.testing.expectEqualStrings(
        \\{"news":{"shown_news_ids":["release-1"]},"gallery":{"sort":"name"}}
    , try toText(allocator, document));
}

//
// A field of a section the flat view does not know is kept, because the merge starts from the section as it is.
//
test "appStateToYaml keeps fields of a section that it does not own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try app_state_format.appStateToYaml(allocator, .{
        .gallerySort = "name",
    }, try parse(allocator,
        \\{"gallery":{"sort":"date","future_field":1}}
    ));

    try std.testing.expectEqualStrings("{\"gallery\":{\"sort\":\"name\",\"future_field\":1}}", try toText(allocator, document));
}

//
// A declared key is read from and written to its own field, and not placed in the ui section.
//
test "setAppStateValue writes a declared key to its own field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state: IAppState = .{};
    try app_state_format.setAppStateValue(allocator, &state, "gallerySort", .{
        .string = "name",
    });

    try std.testing.expectEqualStrings("name", state.gallerySort.?);
    try std.testing.expect(state.ui == null);
    const value = try app_state_format.getAppStateValue(allocator, state, "gallerySort");
    try std.testing.expectEqualStrings("name", value.?.string);
}

//
// Every declared key takes a value of its own kind and reads back what was written.
//
test "setAppStateValue and getAppStateValue round trip every declared key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state: IAppState = .{};
    var searches = std.json.Array.init(allocator);
    try searches.append(.{
        .string = "cats",
    });
    try app_state_format.setAppStateValue(allocator, &state, "lastFolder", .{
        .string = "/folder",
    });
    try app_state_format.setAppStateValue(allocator, &state, "lastDownloadFolder", .{
        .string = "/downloads",
    });
    try app_state_format.setAppStateValue(allocator, &state, "devToolsOpen", .{
        .bool = true,
    });
    try app_state_format.setAppStateValue(allocator, &state, "recentSearches", .{
        .array = searches,
    });
    try app_state_format.setAppStateValue(allocator, &state, "galleryRowHeight", .{
        .integer = 240,
    });

    try std.testing.expectEqualStrings("/folder", state.lastFolder.?);
    try std.testing.expectEqualStrings("/downloads", state.lastDownloadFolder.?);
    try std.testing.expect(state.devToolsOpen.?);
    try std.testing.expectEqualStrings("cats", state.recentSearches.?[0]);
    try std.testing.expectEqual(@as(i64, 240), state.galleryRowHeight.?.integer);
    try std.testing.expectEqualStrings("/folder", (try app_state_format.getAppStateValue(allocator, state, "lastFolder")).?.string);
    try std.testing.expectEqualStrings("/downloads", (try app_state_format.getAppStateValue(allocator, state, "lastDownloadFolder")).?.string);
    try std.testing.expect((try app_state_format.getAppStateValue(allocator, state, "devToolsOpen")).?.bool);
    try std.testing.expectEqualStrings("cats", (try app_state_format.getAppStateValue(allocator, state, "recentSearches")).?.array.items[0].string);
    try std.testing.expectEqual(@as(i64, 240), (try app_state_format.getAppStateValue(allocator, state, "galleryRowHeight")).?.integer);
}

//
// A key the document does not declare is read from and written to the ui section.
//
test "setAppStateValue writes a key the document does not declare to the ui section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state: IAppState = .{};
    try app_state_format.setAppStateValue(allocator, &state, "sidebar-collapsed-databases", .{
        .bool = true,
    });

    try std.testing.expectEqualStrings("{\"sidebar-collapsed-databases\":true}", try toText(allocator, std.json.Value{
        .object = state.ui.?,
    }));
    try std.testing.expect((try app_state_format.getAppStateValue(allocator, state, "sidebar-collapsed-databases")).?.bool);
}

//
// A key nothing has been stored under reads as undefined.
//
test "getAppStateValue returns undefined for a key nothing has been stored under" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const state: IAppState = .{};
    try std.testing.expect((try app_state_format.getAppStateValue(allocator, state, "gallerySort")) == null);
    try std.testing.expect((try app_state_format.getAppStateValue(allocator, state, "recentSearches")) == null);
    try std.testing.expect((try app_state_format.getAppStateValue(allocator, state, "sidebar-collapsed-databases")) == null);
}

//
// Writing nothing removes a key rather than leaving it as it was.
//
test "setAppStateValue with no value removes a declared key and a ui key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state: IAppState = .{
        .gallerySort = "name",
        .recentSearches = &.{"cats"},
    };
    try app_state_format.setAppStateValue(allocator, &state, "gallerySort", null);
    try app_state_format.setAppStateValue(allocator, &state, "recentSearches", null);
    try std.testing.expect(state.gallerySort == null);
    try std.testing.expect(state.recentSearches == null);

    try app_state_format.setAppStateValue(allocator, &state, "sidebar-collapsed-databases", .{
        .bool = true,
    });
    try app_state_format.setAppStateValue(allocator, &state, "sidebar-collapsed-databases", null);
    try std.testing.expectEqual(@as(usize, 0), state.ui.?.count());
    try std.testing.expect((try app_state_format.getAppStateValue(allocator, state, "sidebar-collapsed-databases")) == null);
}

//
// Clearing a ui key that was never set changes nothing, and in particular does not create the ui section.
//
test "setAppStateValue clearing a ui key that was never set changes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state: IAppState = .{};
    try app_state_format.setAppStateValue(allocator, &state, "never-set", null);

    try std.testing.expect(state.ui == null);
}

//
// Setting a ui key again replaces its value rather than adding a second one.
//
test "setAppStateValue replaces the value of a ui key that is already set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state: IAppState = .{};
    try app_state_format.setAppStateValue(allocator, &state, "width", .{
        .integer = 100,
    });
    try app_state_format.setAppStateValue(allocator, &state, "width", .{
        .integer = 200,
    });

    try std.testing.expectEqual(@as(usize, 1), state.ui.?.count());
    try std.testing.expectEqual(@as(i64, 200), state.ui.?.get("width").?.integer);
}

//
// Every key that has a value is listed together under its own name.
//
test "appStateSettings lists every key that has a value under its own name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state: IAppState = .{
        .gallerySort = "name",
        .devToolsOpen = true,
        .recentSearches = &.{"cats"},
    };
    try app_state_format.setAppStateValue(allocator, &state, "sidebar-collapsed-databases", .{
        .bool = true,
    });

    const settings = try app_state_format.appStateSettings(allocator, state);

    try std.testing.expectEqualStrings(
        \\{"devToolsOpen":true,"recentSearches":["cats"],"gallerySort":"name","sidebar-collapsed-databases":true}
    , try toText(allocator, std.json.Value{
        .object = settings,
    }));
}

//
// A key with no value is left out rather than listed as undefined.
//
test "appStateSettings leaves out a key with no value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const settings = try app_state_format.appStateSettings(allocator, .{});

    try std.testing.expectEqual(@as(usize, 0), settings.count());
}

//
// The value arrives as JSON, so a declared key given a value of the wrong kind is refused with an error that names the
// key, and the state is left as it was.
//
test "setAppStateValue refuses a declared key given a value of the wrong kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mixed = std.json.Array.init(allocator);
    try mixed.append(.{
        .string = "a",
    });
    try mixed.append(.{
        .bool = true,
    });
    const cases = [_]struct {
        key: []const u8,
        value: std.json.Value,
        message: []const u8,
    }{
        .{
            .key = "lastFolder",
            .value = .{
                .bool = true,
            },
            .message = "The state key \"lastFolder\" cannot hold that value, it holds a string.",
        },
        .{
            .key = "lastDownloadFolder",
            .value = .{
                .integer = 1,
            },
            .message = "The state key \"lastDownloadFolder\" cannot hold that value, it holds a string.",
        },
        .{
            .key = "devToolsOpen",
            .value = .{
                .string = "yes",
            },
            .message = "The state key \"devToolsOpen\" cannot hold that value, it holds a boolean.",
        },
        .{
            .key = "recentSearches",
            .value = .{
                .string = "cats",
            },
            .message = "The state key \"recentSearches\" cannot hold that value, it holds a list of strings.",
        },
        .{
            .key = "recentSearches",
            .value = .{
                .array = mixed,
            },
            .message = "The state key \"recentSearches\" cannot hold that value, it holds a list of strings.",
        },
        .{
            .key = "gallerySort",
            .value = .null,
            .message = "The state key \"gallerySort\" cannot hold that value, it holds a string.",
        },
        .{
            .key = "galleryRowHeight",
            .value = .{
                .string = "tall",
            },
            .message = "The state key \"galleryRowHeight\" cannot hold that value, it holds a number.",
        },
    };
    for (cases) |testCase| {
        var state: IAppState = .{};
        try std.testing.expectError(error.Thrown, app_state_format.setAppStateValue(allocator, &state, testCase.key, testCase.value));
        try std.testing.expectEqualStrings(testCase.message, utils.errors.lastErrorMessage());
        try std.testing.expect(state.lastFolder == null);
        try std.testing.expect(state.devToolsOpen == null);
        try std.testing.expect(state.recentSearches == null);
        try std.testing.expect(state.galleryRowHeight == null);
    }
}

//
// A key kept in the ui section holds what the interface can hold, so an object or a null is refused and nothing is
// written.
//
test "setAppStateValue refuses a ui key given a value the interface cannot hold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state: IAppState = .{};
    try std.testing.expectError(error.Thrown, app_state_format.setAppStateValue(allocator, &state, "nested", .{
        .object = .empty,
    }));
    try std.testing.expectEqualStrings(
        "The state key \"nested\" cannot hold that value, it holds a boolean, a number, a string or a list of strings.",
        utils.errors.lastErrorMessage(),
    );
    try std.testing.expectError(error.Thrown, app_state_format.setAppStateValue(allocator, &state, "nothing", .null));
    try std.testing.expect(state.ui == null);
}
