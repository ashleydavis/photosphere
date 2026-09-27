//
// Port of `path.join` from Node's `path` module (lib/path.js), which the TypeScript code calls as `join` from
// "path". Node joins the segments and then normalizes the result: it resolves `.` and `..` segments, collapses
// repeated separators and, on Windows, turns every `/` into `\`. `std.fs.path.join` does none of that, so the
// TypeScript output cannot be matched with it. Only join and the normalize it calls, dirname, basename (without a
// suffix) and extname are ported.
//

const std = @import("std");
const builtin = @import("builtin");

//
// Tests for a separator of POSIX paths.
//
fn isPosixPathSeparator(code: u8) bool {
    return code == '/';
}

//
// Tests for a separator of Windows paths.
//
fn isPathSeparator(code: u8) bool {
    return code == '/' or code == '\\';
}

//
// Tests for a drive letter.
//
fn isWindowsDeviceRoot(code: u8) bool {
    return (code >= 'A' and code <= 'Z') or (code >= 'a' and code <= 'z');
}

//
// Resolves . and .. elements in a path with directory names.
//
fn normalizeString(allocator: std.mem.Allocator, path: []const u8, allowAboveRoot: bool, separator: u8, isSeparator: *const fn (u8) bool) ![]const u8 {
    var res: std.ArrayList(u8) = .empty;
    var lastSegmentLength: usize = 0;
    var lastSlash: isize = -1;
    var dots: isize = 0;
    var code: u8 = 0;
    var index: usize = 0;
    while (index <= path.len) : (index += 1) {
        if (index < path.len) {
            code = path[index];
        }
        else if (isSeparator(code)) {
            break;
        }
        else {
            code = '/';
        }

        const position: isize = @intCast(index);
        if (isSeparator(code)) {
            if (lastSlash == position - 1 or dots == 1) {
                // NOOP
            }
            else if (dots == 2) {
                if (res.items.len < 2 or lastSegmentLength != 2 or res.items[res.items.len - 1] != '.' or res.items[res.items.len - 2] != '.') {
                    if (res.items.len > 2) {
                        if (std.mem.lastIndexOfScalar(u8, res.items, separator)) |lastSlashIndex| {
                            res.shrinkRetainingCapacity(lastSlashIndex);
                            const previousSlash = std.mem.lastIndexOfScalar(u8, res.items, separator);
                            lastSegmentLength = if (previousSlash) |slash| res.items.len - 1 - slash else res.items.len;
                        }
                        else {
                            res.clearRetainingCapacity();
                            lastSegmentLength = 0;
                        }
                        lastSlash = position;
                        dots = 0;
                        continue;
                    }
                    else if (res.items.len != 0) {
                        res.clearRetainingCapacity();
                        lastSegmentLength = 0;
                        lastSlash = position;
                        dots = 0;
                        continue;
                    }
                }
                if (allowAboveRoot) {
                    if (res.items.len > 0) {
                        try res.append(allocator, separator);
                    }
                    try res.appendSlice(allocator, "..");
                    lastSegmentLength = 2;
                }
            }
            else {
                const segmentStart: usize = @intCast(lastSlash + 1);
                if (res.items.len > 0) {
                    try res.append(allocator, separator);
                }
                try res.appendSlice(allocator, path[segmentStart..index]);
                lastSegmentLength = @intCast(position - lastSlash - 1);
            }
            lastSlash = position;
            dots = 0;
        }
        else if (code == '.' and dots != -1) {
            dots += 1;
        }
        else {
            dots = -1;
        }
    }
    return res.items;
}

//
// The POSIX flavour of the path functions (`path.posix`).
//
pub const posix = struct {
    //
    // Normalizes a POSIX path (`path.posix.normalize`).
    //
    pub fn normalize(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        if (path.len == 0) {
            return ".";
        }

        const isAbsolute = path[0] == '/';
        const trailingSeparator = path[path.len - 1] == '/';

        const normalized = try normalizeString(allocator, path, !isAbsolute, '/', isPosixPathSeparator);

        if (normalized.len == 0) {
            if (isAbsolute) {
                return "/";
            }
            return if (trailingSeparator) "./" else ".";
        }
        return std.mem.concat(allocator, u8, &.{ if (isAbsolute) "/" else "", normalized, if (trailingSeparator) "/" else "" });
    }

    //
    // Joins POSIX path segments and normalizes the result (`path.posix.join`).
    //
    pub fn join(allocator: std.mem.Allocator, paths: []const []const u8) ![]const u8 {
        var joined: ?std.ArrayList(u8) = null;
        for (paths) |segment| {
            if (segment.len > 0) {
                if (joined) |*text| {
                    try text.append(allocator, '/');
                    try text.appendSlice(allocator, segment);
                }
                else {
                    joined = .empty;
                    try joined.?.appendSlice(allocator, segment);
                }
            }
        }
        if (joined) |text| {
            return normalize(allocator, text.items);
        }
        return ".";
    }

    //
    // The directory of a POSIX path (`path.posix.dirname`).
    //
    pub fn dirname(path: []const u8) []const u8 {
        if (path.len == 0) {
            return ".";
        }
        const hasRoot = path[0] == '/';
        var end: ?usize = null;
        var matchedSlash = true;
        var index = path.len - 1;
        while (index >= 1) : (index -= 1) {
            if (path[index] == '/') {
                if (!matchedSlash) {
                    end = index;
                    break;
                }
            }
            else {
                // We saw the first non-path separator
                matchedSlash = false;
            }
        }

        const directoryEnd = end orelse {
            return if (hasRoot) "/" else ".";
        };
        if (hasRoot and directoryEnd == 1) {
            return "//";
        }
        return path[0..directoryEnd];
    }

    //
    // The last portion of a POSIX path (`path.posix.basename(path)`).
    //
    pub fn basename(path: []const u8) []const u8 {
        var start: usize = 0;
        var end: ?usize = null;
        var matchedSlash = true;
        var index = path.len;
        while (index > 0) {
            index -= 1;
            if (path[index] == '/') {
                // If we reached a path separator that was not part of a set of path
                // separators at the end of the string, stop now
                if (!matchedSlash) {
                    start = index + 1;
                    break;
                }
            }
            else if (end == null) {
                // We saw the first non-path separator, mark this as the end of our
                // path component
                matchedSlash = false;
                end = index + 1;
            }
        }

        const componentEnd = end orelse {
            return "";
        };
        return path[start..componentEnd];
    }

    //
    // The extension of a POSIX path (`path.posix.extname`).
    //
    pub fn extname(path: []const u8) []const u8 {
        return extnameFrom(path, 0, isPosixPathSeparator);
    }
};

//
// The Windows flavour of the path functions (`path.win32`).
//
pub const win32 = struct {
    //
    // Normalizes a Windows path (`path.win32.normalize`).
    //
    pub fn normalize(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        const len = path.len;
        if (len == 0) {
            return ".";
        }
        var rootEnd: usize = 0;
        var device: ?[]const u8 = null;
        var isAbsolute = false;
        const code = path[0];

        // Try to match a root
        if (len == 1) {
            // `path` contains just a single char, exit early to avoid
            // unnecessary work
            return if (isPosixPathSeparator(code)) "\\" else path;
        }
        if (isPathSeparator(code)) {
            // Possible UNC root

            // If we started with a separator, we know we at least have an absolute
            // path of some kind (UNC or otherwise)
            isAbsolute = true;

            if (isPathSeparator(path[1])) {
                // Matched double path separator at beginning
                var j: usize = 2;
                var last = j;
                // Match 1 or more non-path separators
                while (j < len and !isPathSeparator(path[j])) {
                    j += 1;
                }
                if (j < len and j != last) {
                    const firstPart = path[last..j];
                    // Matched!
                    last = j;
                    // Match 1 or more path separators
                    while (j < len and isPathSeparator(path[j])) {
                        j += 1;
                    }
                    if (j < len and j != last) {
                        // Matched!
                        last = j;
                        // Match 1 or more non-path separators
                        while (j < len and !isPathSeparator(path[j])) {
                            j += 1;
                        }
                        if (j == len) {
                            // We matched a UNC root only
                            // Return the normalized version of the UNC root since there
                            // is nothing left to process
                            return std.mem.concat(allocator, u8, &.{ "\\\\", firstPart, "\\", path[last..], "\\" });
                        }
                        if (j != last) {
                            // We matched a UNC root with leftovers
                            device = try std.mem.concat(allocator, u8, &.{ "\\\\", firstPart, "\\", path[last..j] });
                            rootEnd = j;
                        }
                    }
                }
            }
            else {
                rootEnd = 1;
            }
        }
        else if (isWindowsDeviceRoot(code) and path[1] == ':') {
            // Possible device root
            device = path[0..2];
            rootEnd = 2;
            if (len > 2 and isPathSeparator(path[2])) {
                // Treat separator following drive name as an absolute path
                // indicator
                isAbsolute = true;
                rootEnd = 3;
            }
        }

        var tail: []const u8 = if (rootEnd < len) try normalizeString(allocator, path[rootEnd..], !isAbsolute, '\\', isPathSeparator) else "";
        if (tail.len == 0 and !isAbsolute) {
            tail = ".";
        }
        if (tail.len > 0 and isPathSeparator(path[len - 1])) {
            tail = try std.mem.concat(allocator, u8, &.{ tail, "\\" });
        }
        if (device) |deviceRoot| {
            return std.mem.concat(allocator, u8, &.{ deviceRoot, if (isAbsolute) "\\" else "", tail });
        }
        return std.mem.concat(allocator, u8, &.{ if (isAbsolute) "\\" else "", tail });
    }

    //
    // Joins Windows path segments and normalizes the result (`path.win32.join`).
    //
    pub fn join(allocator: std.mem.Allocator, paths: []const []const u8) ![]const u8 {
        var joined: std.ArrayList(u8) = .empty;
        var firstPart: ?[]const u8 = null;
        for (paths) |segment| {
            if (segment.len > 0) {
                if (firstPart == null) {
                    firstPart = segment;
                }
                else {
                    try joined.append(allocator, '\\');
                }
                try joined.appendSlice(allocator, segment);
            }
        }

        const first = firstPart orelse return ".";

        // Make sure that the joined path doesn't start with two slashes, because
        // normalize() will mistake it for a UNC path then.
        //
        // This step is skipped when it is very clear that the user actually
        // intended to point at a UNC path. This is assumed when the first
        // non-empty string arguments starts with exactly two slashes followed by
        // at least one more non-slash character.
        var needsReplace = true;
        var slashCount: usize = 0;
        if (isPathSeparator(first[0])) {
            slashCount += 1;
            const firstLen = first.len;
            if (firstLen > 1 and isPathSeparator(first[1])) {
                slashCount += 1;
                if (firstLen > 2) {
                    if (isPathSeparator(first[2])) {
                        slashCount += 1;
                    }
                    else {
                        // We matched a UNC path in the first part
                        needsReplace = false;
                    }
                }
            }
        }
        var text: []const u8 = joined.items;
        if (needsReplace) {
            // Find any more consecutive slashes we need to replace
            while (slashCount < text.len and isPathSeparator(text[slashCount])) {
                slashCount += 1;
            }

            // Replace the slashes if needed
            if (slashCount >= 2) {
                text = try std.mem.concat(allocator, u8, &.{ "\\", text[slashCount..] });
            }
        }

        return normalize(allocator, text);
    }

    //
    // The directory of a Windows path (`path.win32.dirname`).
    //
    pub fn dirname(path: []const u8) []const u8 {
        const len = path.len;
        if (len == 0) {
            return ".";
        }
        var rootEnd: ?usize = null;
        var offset: usize = 0;
        const code = path[0];

        if (len == 1) {
            // `path` contains just a path separator, exit early to avoid
            // unnecessary work or a dot.
            return if (isPathSeparator(code)) path else ".";
        }

        // Try to match a root
        if (isPathSeparator(code)) {
            // Possible UNC root

            rootEnd = 1;
            offset = 1;

            if (isPathSeparator(path[1])) {
                // Matched double path separator at beginning
                var j: usize = 2;
                var last = j;
                // Match 1 or more non-path separators
                while (j < len and !isPathSeparator(path[j])) {
                    j += 1;
                }
                if (j < len and j != last) {
                    // Matched!
                    last = j;
                    // Match 1 or more path separators
                    while (j < len and isPathSeparator(path[j])) {
                        j += 1;
                    }
                    if (j < len and j != last) {
                        // Matched!
                        last = j;
                        // Match 1 or more non-path separators
                        while (j < len and !isPathSeparator(path[j])) {
                            j += 1;
                        }
                        if (j == len) {
                            // We matched a UNC root only
                            return path;
                        }
                        if (j != last) {
                            // We matched a UNC root with leftovers

                            // Offset by 1 to include the separator after the UNC root to
                            // treat it as a "normal root" on top of a (UNC) root
                            rootEnd = j + 1;
                            offset = j + 1;
                        }
                    }
                }
            }
        }
        else if (isWindowsDeviceRoot(code) and path[1] == ':') {
            // Possible device root
            rootEnd = if (len > 2 and isPathSeparator(path[2])) 3 else 2;
            offset = rootEnd.?;
        }

        var end: ?usize = null;
        var matchedSlash = true;
        var index = len;
        while (index > offset) {
            index -= 1;
            if (isPathSeparator(path[index])) {
                if (!matchedSlash) {
                    end = index;
                    break;
                }
            }
            else {
                // We saw the first non-path separator
                matchedSlash = false;
            }
        }

        const directoryEnd = end orelse (rootEnd orelse {
            return ".";
        });
        return path[0..directoryEnd];
    }

    //
    // The last portion of a Windows path (`path.win32.basename(path)`).
    //
    pub fn basename(path: []const u8) []const u8 {
        var start: usize = 0;
        var end: ?usize = null;
        var matchedSlash = true;

        // Check for a drive letter prefix so as not to mistake the following
        // path separator as an extra separator at the end of the path that can be
        // disregarded
        if (path.len >= 2 and isWindowsDeviceRoot(path[0]) and path[1] == ':') {
            start = 2;
        }

        var index = path.len;
        while (index > start) {
            index -= 1;
            if (isPathSeparator(path[index])) {
                // If we reached a path separator that was not part of a set of path
                // separators at the end of the string, stop now
                if (!matchedSlash) {
                    start = index + 1;
                    break;
                }
            }
            else if (end == null) {
                // We saw the first non-path separator, mark this as the end of our
                // path component
                matchedSlash = false;
                end = index + 1;
            }
        }

        const componentEnd = end orelse {
            return "";
        };
        return path[start..componentEnd];
    }

    //
    // The extension of a Windows path (`path.win32.extname`).
    //
    pub fn extname(path: []const u8) []const u8 {
        var start: usize = 0;

        // Check for a drive letter prefix so as not to mistake the following
        // path separator as an extra separator at the end of the path that can be
        // disregarded
        if (path.len >= 2 and path[1] == ':' and isWindowsDeviceRoot(path[0])) {
            start = 2;
        }
        return extnameFrom(path, start, isPathSeparator);
    }
};

//
// Joins path segments and normalizes the result, with the rules of the platform the program runs on
// (`path.join`).
//
pub fn join(allocator: std.mem.Allocator, paths: []const []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        return win32.join(allocator, paths);
    }
    return posix.join(allocator, paths);
}

//
// The body of extname, which is the same for both platforms once the start of the path is known.
// (No Node counterpart: the loop is written out in each of Node's extname functions.)
//
fn extnameFrom(path: []const u8, start: usize, isSeparator: *const fn (u8) bool) []const u8 {
    var startDot: ?usize = null;
    var startPart: usize = start;
    var end: ?usize = null;
    var matchedSlash = true;

    // Track the state of characters (if any) we see before our first dot and
    // after any path separator we find
    var preDotState: i8 = 0;
    var index = path.len;
    while (index > start) {
        index -= 1;
        const code = path[index];
        if (isSeparator(code)) {
            // If we reached a path separator that was not part of a set of path
            // separators at the end of the string, stop now
            if (!matchedSlash) {
                startPart = index + 1;
                break;
            }
            continue;
        }
        if (end == null) {
            // We saw the first non-path separator, mark this as the end of our
            // extension
            matchedSlash = false;
            end = index + 1;
        }
        if (code == '.') {
            // If this is our first dot, mark it as the start of our extension
            if (startDot == null) {
                startDot = index;
            }
            else if (preDotState != 1) {
                preDotState = 1;
            }
        }
        else if (startDot != null) {
            // We saw a non-dot and non-path separator before our dot, so we should
            // have a good chance at having a non-empty extension
            preDotState = -1;
        }
    }

    const dot = startDot orelse {
        return "";
    };
    const extensionEnd = end orelse {
        return "";
    };
    if (preDotState == 0 or
        // We saw a non-dot character immediately before the dot
        (preDotState == 1 and dot == extensionEnd - 1 and dot == startPart + 1))
    {
        // The (right-most) trimmed path component is exactly '..'
        return "";
    }
    return path[dot..extensionEnd];
}

//
// The directory of a path, with the rules of the platform the program runs on (`path.dirname`).
//
pub fn dirname(path: []const u8) []const u8 {
    if (builtin.os.tag == .windows) {
        return win32.dirname(path);
    }
    return posix.dirname(path);
}

//
// The last portion of a path, with the rules of the platform the program runs on (`path.basename(path)`).
//
pub fn basename(path: []const u8) []const u8 {
    if (builtin.os.tag == .windows) {
        return win32.basename(path);
    }
    return posix.basename(path);
}

//
// The extension of a path, with the rules of the platform the program runs on (`path.extname`).
//
pub fn extname(path: []const u8) []const u8 {
    if (builtin.os.tag == .windows) {
        return win32.extname(path);
    }
    return posix.extname(path);
}
