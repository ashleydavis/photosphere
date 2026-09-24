const std = @import("std");
const utils = @import("utils-zig");
const yaml = @import("yaml.zig");
const fetch_module = @import("fetch.zig");
const errors = utils.errors;
const fetch = fetch_module.fetch;

//
// A labelled URL used as either an inline link or CTA action in a news item.
//
pub const INewsLink = struct {
    //
    // Visible label shown to the user.
    //
    label: []const u8,

    //
    // External URL opened when the label is clicked.
    //
    url: []const u8,
};

//
// A single news item parsed from the published news.yaml feed.
//
pub const INewsItem = struct {
    //
    // Stable identifier used to track whether this item has already been shown.
    //
    id: []const u8,

    //
    // Message body displayed in the toast.
    //
    message: []const u8,

    //
    // Optional color variant for the toast. Defaults to 'primary' when omitted.
    //
    color: ?[]const u8 = null,

    //
    // Optional auto-dismiss duration in milliseconds. 0 (or omitted) means no auto-dismiss.
    //
    duration: ?f64 = null,

    //
    // Optional inline link rendered below the toast message.
    //
    link: ?INewsLink = null,

    //
    // Optional CTA button rendered alongside the toast message.
    //
    action: ?INewsLink = null,
};

// Not ported: INewsFeed (the parsed feed is a std.json.Value here).

//
// Converts a JavaScript value to its string form for a template string (`${value}`): strings as they are,
// numbers and booleans as text, everything else "undefined" or "null".
//
fn templateText(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const u8 {
    const present = value orelse return "undefined";
    return switch (present) {
        .string => |text| text,
        .null => "null",
        .bool => |flag| if (flag) "true" else "false",
        .integer => |integer| std.fmt.allocPrint(allocator, "{d}", .{integer}),
        .float => |float| std.fmt.allocPrint(allocator, "{d}", .{float}),
        .number_string => |text| text,
        .array => "",
        .object => "[object Object]",
    };
}

//
// JavaScript truthiness of a parsed value.
//
fn isTruthy(value: ?std.json.Value) bool {
    const present = value orelse return false;
    return switch (present) {
        .null => false,
        .bool => |flag| flag,
        .integer => |integer| integer != 0,
        .float => |float| float != 0 and !std.math.isNan(float),
        .string => |text| text.len > 0,
        else => true,
    };
}

//
// Converts a link of a news item (kept only when truthy, as `if (item.link)` tests it).
//
fn toLink(allocator: std.mem.Allocator, value: ?std.json.Value) !?INewsLink {
    if (!isTruthy(value)) {
        return null;
    }
    const object = switch (value.?) {
        .object => |object| object,
        else => return INewsLink{ .label = "undefined", .url = "undefined" },
    };
    return INewsLink{
        .label = try templateText(allocator, object.get("label")),
        .url = try templateText(allocator, object.get("url")),
    };
}

//
// Converts a `file://` URL to a path (`fileURLToPath`): the path after the host, percent-decoded.
//
fn fileURLToPath(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var rest = url["file://".len..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        rest = rest[slash..];
    }
    var result: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < rest.len) {
        if (rest[index] == '%' and index + 2 < rest.len) {
            if (std.fmt.parseInt(u8, rest[index + 1 .. index + 3], 16)) |byte| {
                try result.append(allocator, byte);
                index += 3;
                continue;
            }
            else |_| {}
        }
        try result.append(allocator, rest[index]);
        index += 1;
    }
    return result.items;
}

//
// Fetches the news feed at the given URL and returns its items.
// Supports file:// URLs (used by smoke tests) and http(s):// URLs (production).
// Throws on HTTP errors, malformed YAML, or invalid item shapes.
//
pub fn fetchNews(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]const INewsItem {
    var body: []const u8 = undefined;
    if (std.mem.startsWith(u8, url, "file://")) {
        const filePath = try fileURLToPath(allocator, url);
        body = try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
    }
    else {
        const response = try fetch(allocator, io, url);
        if (!response.ok) {
            return errors.throwError("Failed to fetch news feed: HTTP {d}", .{response.status});
        }
        body = response.body;
    }

    const parsed = try yaml.load(allocator, body);
    const items = blk: {
        switch (parsed) {
            .object => |object| {
                if (object.get("items")) |itemsValue| {
                    if (itemsValue == .array) {
                        break :blk itemsValue.array.items;
                    }
                }
            },
            else => {},
        }
        return errors.throwError("Invalid news feed: missing items array", .{});
    };

    for (items) |item| {
        const id: ?std.json.Value = if (item == .object) item.object.get("id") else null;
        if (!isTruthy(item) or id == null or id.? != .string or id.?.string.len == 0) {
            return errors.throwError("Invalid news item: missing id", .{});
        }
        const message: ?std.json.Value = if (item == .object) item.object.get("message") else null;
        if (message == null or message.? != .string or message.?.string.len == 0) {
            return errors.throwError("Invalid news item: missing message", .{});
        }
    }

    var result: std.ArrayList(INewsItem) = .empty;
    for (items) |item| {
        const object = item.object;
        const color = object.get("color");
        const duration = object.get("duration");
        try result.append(allocator, .{
            .id = object.get("id").?.string,
            .message = object.get("message").?.string,
            .color = if (color != null and color.? == .string) color.?.string else null,
            .duration = if (duration != null and duration.? == .integer) @floatFromInt(duration.?.integer) else if (duration != null and duration.? == .float) duration.?.float else null,
            .link = try toLink(allocator, object.get("link")),
            .action = try toLink(allocator, object.get("action")),
        });
    }
    return result.items;
}
