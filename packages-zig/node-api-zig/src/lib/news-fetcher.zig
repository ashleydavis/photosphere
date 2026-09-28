const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const yaml = node_utils.yaml;
const serialization_zig = @import("serialization-zig");
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
// Converts a JavaScript value to its string form for a template string (`${value}`): strings as they are, numbers
// as JavaScript prints them, an array as its elements joined with commas (null and undefined elements as nothing),
// an object as "[object Object]", and undefined and null by name.
//
fn templateText(allocator: std.mem.Allocator, value: ?std.json.Value) anyerror![]const u8 {
    const present = value orelse return "undefined";
    return switch (present) {
        .string => |text| text,
        .null => "null",
        .bool => |flag| if (flag) "true" else "false",
        .integer => |integer| jsNumberText(allocator, @floatFromInt(integer)),
        .float => |float| jsNumberText(allocator, float),
        .number_string => |text| jsNumberText(allocator, std.fmt.parseFloat(f64, text) catch std.math.nan(f64)),
        .array => |array| {
            var parts: std.ArrayList([]const u8) = .empty;
            for (array.items) |element| {
                try parts.append(allocator, if (element == .null) "" else try templateText(allocator, element));
            }
            return std.mem.join(allocator, ",", parts.items);
        },
        .object => "[object Object]",
    };
}

//
// `String(number)` for a JavaScript number.
//
fn jsNumberText(allocator: std.mem.Allocator, number: f64) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try serialization_zig.js_number.writeNumber(&output.writer, number);
    return output.written();
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
// Whether a path segment is a single dot of a URL path, written plainly or percent-encoded.
//
fn isSingleDotSegment(segment: []const u8) bool {
    return std.mem.eql(u8, segment, ".") or std.ascii.eqlIgnoreCase(segment, "%2e");
}

//
// Whether a path segment is a double dot of a URL path, written plainly or with either dot percent-encoded.
//
fn isDoubleDotSegment(segment: []const u8) bool {
    return std.mem.eql(u8, segment, "..") or std.ascii.eqlIgnoreCase(segment, ".%2e") or std.ascii.eqlIgnoreCase(segment, "%2e.") or std.ascii.eqlIgnoreCase(segment, "%2e%2e");
}

//
// Whether a path segment is a Windows drive letter ("C:" or "C|"), which a `..` in a file URL never removes.
//
fn isDriveLetterSegment(segment: []const u8) bool {
    return segment.len == 2 and std.ascii.isAlphabetic(segment[0]) and (segment[1] == ':' or segment[1] == '|');
}

//
// The path of a file URL as the URL parser leaves it: `.` and `..` segments resolved, starting with "/".
//
fn normalizeUrlPath(allocator: std.mem.Allocator, rawPath: []const u8) ![]const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    const withoutLeadingSlash = if (rawPath.len > 0 and rawPath[0] == '/') rawPath[1..] else rawPath;
    var parts = std.mem.splitScalar(u8, withoutLeadingSlash, '/');
    while (parts.next()) |segment| {
        const isLast = parts.peek() == null;
        if (isDoubleDotSegment(segment)) {
            if (segments.items.len > 0 and !(segments.items.len == 1 and isDriveLetterSegment(segments.items[0]))) {
                _ = segments.pop();
            }
            if (isLast) {
                try segments.append(allocator, "");
            }
        }
        else if (isSingleDotSegment(segment)) {
            if (isLast) {
                try segments.append(allocator, "");
            }
        }
        else {
            try segments.append(allocator, segment);
        }
    }
    const joined = try std.mem.join(allocator, "/", segments.items);
    return std.mem.concat(allocator, u8, &.{ "/", joined });
}

//
// Percent-decodes a URL path. A `%` not followed by two hex digits is kept as it is, which is what Bun's
// fileURLToPath does (Node's throws a URIError for it).
//
fn percentDecode(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '%' and index + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[index + 1 .. index + 3], 16)) |byte| {
                try result.append(allocator, byte);
                index += 3;
                continue;
            }
            else |_| {}
        }
        try result.append(allocator, text[index]);
        index += 1;
    }
    return result.items;
}

//
// Node's `fileURLToPath` for a URL starting "file://", as Bun runs it. The URL is parsed first: tabs and
// newlines are dropped, backslashes are slashes, the query and fragment are cut off, "localhost" is no host at
// all, and `.` and `..` segments are resolved. Then the path is checked and percent-decoded. On Windows the path
// uses backslashes and loses the slash before the drive letter ("C:\dir\file"), and a host makes it a UNC path
// ("\\host\share\file").
//
pub fn fileURLToPath(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var cleaned: std.ArrayList(u8) = .empty;
    for (url["file://".len..]) |character| {
        if (character == '\t' or character == '\n' or character == '\r') {
            continue;
        }
        try cleaned.append(allocator, if (character == '\\') '/' else character);
    }
    var rest: []const u8 = cleaned.items;
    if (std.mem.indexOfAny(u8, rest, "?#")) |cut| {
        rest = rest[0..cut];
    }
    const hostEnd = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    var hostname = rest[0..hostEnd];
    if (std.ascii.eqlIgnoreCase(hostname, "localhost")) {
        hostname = "";
    }
    const pathname = try normalizeUrlPath(allocator, rest[hostEnd..]);

    if (builtin.os.tag == .windows) {
        if (std.ascii.indexOfIgnoreCase(pathname, "%2f") != null or std.ascii.indexOfIgnoreCase(pathname, "%5c") != null) {
            errors.recordError("TypeError", "File URL path must not include encoded \\ or / characters", .{});
            return error.Thrown;
        }
        const decoded = try allocator.dupe(u8, try percentDecode(allocator, pathname));
        std.mem.replaceScalar(u8, decoded, '/', '\\');
        if (hostname.len > 0) {
            return std.mem.concat(allocator, u8, &.{ "\\\\", hostname, decoded });
        }
        if (decoded.len < 3 or !std.ascii.isAlphabetic(decoded[1]) or decoded[2] != ':') {
            errors.recordError("TypeError", "File URL path must be absolute", .{});
            return error.Thrown;
        }
        return decoded[1..];
    }

    if (hostname.len > 0) {
        errors.recordError("TypeError", "File URL host must be \"localhost\" or empty on {s}", .{if (builtin.os.tag == .macos) "darwin" else @tagName(builtin.os.tag)});
        return error.Thrown;
    }
    if (std.ascii.indexOfIgnoreCase(pathname, "%2f") != null) {
        errors.recordError("TypeError", "File URL path must not include encoded / characters", .{});
        return error.Thrown;
    }
    return percentDecode(allocator, pathname);
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
