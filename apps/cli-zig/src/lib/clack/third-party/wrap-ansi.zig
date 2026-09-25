//
// Port of the third-party `wrap-ansi` package (v9.0.2), used by the clack prompts to wrap each frame
// to the terminal width (this file has no TypeScript counterpart in the repo).
// Only the options used by clack are supported: `{ hard: true, trim: false }` with word wrapping on.
// A null column count stands for `process.stdout.columns` being undefined (stdout is not a TTY), for
// which wrap-ansi returns every line unchanged.
//

const std = @import("std");
const string_width = @import("string-width.zig");
const stringWidth = string_width.stringWidth;
const decodeAt = string_width.decodeAt;

//
// The code that ends a foreground color (and resets the tracked escape code).
//
const END_CODE = 39;

//
// The OSC 8 hyperlink prefix that follows ESC.
//
const ANSI_ESCAPE_LINK = "]8;;";

//
// The close code of an ansi-styles open code (`ansiStyles.codes.get(code)`), or null when there is none.
//
fn closeCodeFor(code: u32) ?u32 {
    return switch (code) {
        0 => 0,
        1, 2 => 22,
        3 => 23,
        4 => 24,
        53 => 55,
        7 => 27,
        8 => 28,
        9 => 29,
        30...37, 90...97 => 39,
        40...47, 100...107 => 49,
        else => null,
    };
}

//
// True when the code point starts an escape sequence (ESC or CSI).
//
fn isEscape(codePoint: u21) bool {
    return codePoint == 0x1B or codePoint == 0x9B;
}

//
// Appends a character to the last row.
//
fn appendToLastRow(allocator: std.mem.Allocator, rows: *std.ArrayList(std.ArrayList(u8)), text: []const u8) !void {
    try rows.items[rows.items.len - 1].appendSlice(allocator, text);
}

//
// Starts a new row with the given text.
//
fn pushRow(allocator: std.mem.Allocator, rows: *std.ArrayList(std.ArrayList(u8)), text: []const u8) !void {
    var row: std.ArrayList(u8) = .empty;
    try row.appendSlice(allocator, text);
    try rows.append(allocator, row);
}

//
// Wrap a long word across multiple rows
// Ansi escape codes do not count towards length
//
fn wrapWord(allocator: std.mem.Allocator, rows: *std.ArrayList(std.ArrayList(u8)), word: []const u8, columns: usize) !void {
    var isInsideEscape = false;
    var isInsideLinkEscape = false;
    var visible = stringWidth(rows.items[rows.items.len - 1].items);

    var index: usize = 0;
    while (index < word.len) {
        const decoded = decodeAt(word, index);
        const character = word[index .. index + decoded.length];
        const characterLength = stringWidth(character);
        const next_index = index + decoded.length;

        if (visible + characterLength <= columns) {
            try appendToLastRow(allocator, rows, character);
        }
        else {
            try pushRow(allocator, rows, character);
            visible = 0;
        }

        if (isEscape(decoded.codePoint)) {
            isInsideEscape = true;
            isInsideLinkEscape = std.mem.startsWith(u8, word[next_index..], ANSI_ESCAPE_LINK);
        }

        if (isInsideEscape) {
            if (isInsideLinkEscape) {
                if (decoded.codePoint == 0x07) {
                    isInsideEscape = false;
                    isInsideLinkEscape = false;
                }
            }
            else if (decoded.codePoint == 'm') {
                isInsideEscape = false;
            }

            index = next_index;
            continue;
        }

        visible += characterLength;

        if (visible == columns and next_index < word.len) {
            try pushRow(allocator, rows, "");
            visible = 0;
        }
        index = next_index;
    }

    // It's possible that the last row we copy over is only
    // ansi escape characters, handle this edge-case
    if (visible == 0 and rows.items[rows.items.len - 1].items.len > 0 and rows.items.len > 1) {
        const last = rows.pop().?;
        try rows.items[rows.items.len - 1].appendSlice(allocator, last.items);
    }
}

//
// The result of searching for the next SGR code or hyperlink after an escape character.
//
const EscapeMatch = union(enum) {
    // An SGR code: ESC [ <code> m.
    code: u32,

    // A hyperlink: ESC ] 8 ; ; <uri> BEL.
    uri: []const u8,

    // Nothing matched.
    none,
};

//
// Finds the first `[<digits>m` or `]8;;<uri>BEL` in the text (the unanchored regex used by wrap-ansi).
//
fn findEscapeMatch(text: []const u8) EscapeMatch {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '[') {
            var digit_end = index + 1;
            while (digit_end < text.len and std.ascii.isDigit(text[digit_end])) {
                digit_end += 1;
            }
            if (digit_end > index + 1 and digit_end < text.len and text[digit_end] == 'm') {
                const code = std.fmt.parseInt(u32, text[index + 1 .. digit_end], 10) catch 0;
                return .{ .code = code };
            }
        }
        if (std.mem.startsWith(u8, text[index..], ANSI_ESCAPE_LINK)) {
            const uri_start = index + ANSI_ESCAPE_LINK.len;
            const line_end = std.mem.indexOfScalarPos(u8, text, uri_start, '\n') orelse text.len;
            if (std.mem.lastIndexOfScalar(u8, text[uri_start..line_end], 0x07)) |bell_offset| {
                return .{ .uri = text[uri_start .. uri_start + bell_offset] };
            }
        }
        index += 1;
    }
    return .none;
}

//
// Wraps a single line (wrap-ansi `exec` with `{ hard: true, trim: false }`).
//
fn exec(allocator: std.mem.Allocator, writer: *std.Io.Writer, string: []const u8, columns: usize) !void {
    var escapeCode: ?u32 = null;
    var escapeUrl: ?[]const u8 = null;

    var rows: std.ArrayList(std.ArrayList(u8)) = .empty;
    try pushRow(allocator, &rows, "");

    var word_iterator = std.mem.splitScalar(u8, string, ' ');
    var word_index: usize = 0;
    while (word_iterator.next()) |word| {
        const wordLength = stringWidth(word);
        var rowLength = stringWidth(rows.items[rows.items.len - 1].items);

        if (word_index != 0) {
            if (rowLength >= columns) {
                // If we start with a new word but the current row length equals the length of the columns, add a new row
                try pushRow(allocator, &rows, "");
                rowLength = 0;
            }

            try appendToLastRow(allocator, &rows, " ");
            rowLength += 1;
        }
        word_index += 1;

        // In 'hard' wrap mode, the length of a line is never allowed to extend past 'columns'
        if (wordLength > columns) {
            const signed_columns: i64 = @intCast(columns);
            const signed_length: i64 = @intCast(wordLength);
            const remainingColumns: i64 = signed_columns - @as(i64, @intCast(rowLength));
            const breaksStartingThisLine = 1 + @divFloor(signed_length - remainingColumns - 1, signed_columns);
            const breaksStartingNextLine = @divFloor(signed_length - 1, signed_columns);
            if (breaksStartingNextLine < breaksStartingThisLine) {
                try pushRow(allocator, &rows, "");
            }

            try wrapWord(allocator, &rows, word, columns);
            continue;
        }

        if (rowLength + wordLength > columns and rowLength > 0 and wordLength > 0) {
            try pushRow(allocator, &rows, "");
        }

        try appendToLastRow(allocator, &rows, word);
    }

    var pre_string: std.ArrayList(u8) = .empty;
    for (rows.items, 0..) |row, row_index| {
        if (row_index > 0) {
            try pre_string.append(allocator, '\n');
        }
        try pre_string.appendSlice(allocator, row.items);
    }
    const preString = pre_string.items;

    var index: usize = 0;
    while (index < preString.len) {
        const decoded = decodeAt(preString, index);
        const character = preString[index .. index + decoded.length];
        const next_index = index + decoded.length;
        try writer.writeAll(character);

        if (isEscape(decoded.codePoint)) {
            switch (findEscapeMatch(preString[index..])) {
                .code => |code| {
                    escapeCode = if (code == END_CODE) null else code;
                },
                .uri => |uri| {
                    escapeUrl = if (uri.len == 0) null else uri;
                },
                .none => {},
            }
        }

        const code = if (escapeCode) |open_code| closeCodeFor(open_code) else null;
        const escape_active = escapeCode != null and escapeCode.? != 0 and code != null and code.? != 0;

        if (next_index < preString.len and preString[next_index] == '\n') {
            if (escapeUrl != null) {
                try writer.print("\x1b" ++ ANSI_ESCAPE_LINK ++ "{s}\x07", .{""});
            }

            if (escape_active) {
                try writer.print("\x1b[{d}m", .{code.?});
            }
        }
        else if (decoded.codePoint == '\n') {
            if (escape_active) {
                try writer.print("\x1b[{d}m", .{escapeCode.?});
            }

            if (escapeUrl) |url| {
                try writer.print("\x1b" ++ ANSI_ESCAPE_LINK ++ "{s}\x07", .{url});
            }
        }

        index = next_index;
    }
}

//
// Wraps text to the given number of columns, keeping ANSI escape codes intact (wrap-ansi default export
// with `{ hard: true, trim: false }`). Each line of the input is wrapped separately.
// A null column count returns the text unchanged except that "\r\n" becomes "\n".
//
pub fn wrapAnsi(allocator: std.mem.Allocator, string: []const u8, columns: ?usize) ![]const u8 {
    const normalized = try std.mem.replaceOwned(u8, allocator, string, "\r\n", "\n");
    const column_count = columns orelse return normalized;

    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    const writer = &allocating_writer.writer;
    var line_iterator = std.mem.splitScalar(u8, normalized, '\n');
    var first = true;
    while (line_iterator.next()) |line| {
        if (!first) {
            try writer.writeByte('\n');
        }
        first = false;
        try exec(allocator, writer, line, column_count);
    }
    return allocating_writer.written();
}
