//
// Stand-in for the parts of `node:readline` used by the clack prompts (this file has no TypeScript
// counterpart in the repo):
// - keypress parsing (`emitKeypressEvents`, which turns input bytes into `(char, key)` events),
// - the line editing of a terminal `readline.Interface` (`line` and `cursor`, updated by `_ttyWrite`),
// - PromptInput: the input stream with raw mode handling (`setRawMode`).
// History, completion, undo/redo, yank and the output of the interface are not ported: the prompts create
// the interface without an output and only read `line` and `cursor`.
//

const std = @import("std");
const tty = @import("../../tty.zig");
const string_width = @import("string-width.zig");

//
// A parsed key (node:readline `Key`).
//
pub const Key = struct {
    // The raw characters of the key.
    sequence: []const u8,

    // The name of the key ("return", "up", "a", ...), or null for characters without a name.
    name: ?[]const u8,

    // True when Ctrl was held.
    ctrl: bool,

    // True when Meta (Alt or a preceding escape) was held.
    meta: bool,

    // True when Shift was held.
    shift: bool,
};

//
// A keypress event: the character (undefined in TypeScript for escape sequences) and the key.
//
pub const Keypress = struct {
    // The typed character, or null for escape sequences.
    char: ?[]const u8,

    // The parsed key.
    key: Key,
};

//
// The escape character.
//
const kEscape = "\x1b";

//
// Reads characters (one code point at a time) from a byte slice; returns "" past the end
// (like the empty string fed to emitKeys when an escape sequence times out).
//
const CharacterReader = struct {
    // The bytes being parsed.
    bytes: []const u8,

    // The position of the next character.
    position: usize,

    // True when the parser tried to read past the end.
    exhausted: bool,

    //
    // Returns the next character, or "" at the end.
    //
    fn next(self: *CharacterReader) []const u8 {
        if (self.position >= self.bytes.len) {
            self.exhausted = true;
            return "";
        }
        const decoded = string_width.decodeAt(self.bytes, self.position);
        const character = self.bytes[self.position .. self.position + decoded.length];
        self.position += decoded.length;
        return character;
    }
};

//
// The key names of the escape sequence codes (the switch in node's emitKeys).
//
const CodeName = struct {
    // The code (the characters after ESC without parameters, e.g. "[A").
    code: []const u8,

    // The key name.
    name: []const u8,

    // True when the code implies Shift.
    shift: bool,

    // True when the code implies Ctrl.
    ctrl: bool,
};

//
// The escape sequence codes that have key names.
//
const code_names = [_]CodeName{
    .{ .code = "OP", .name = "f1", .shift = false, .ctrl = false },
    .{ .code = "OQ", .name = "f2", .shift = false, .ctrl = false },
    .{ .code = "OR", .name = "f3", .shift = false, .ctrl = false },
    .{ .code = "OS", .name = "f4", .shift = false, .ctrl = false },
    .{ .code = "[11~", .name = "f1", .shift = false, .ctrl = false },
    .{ .code = "[12~", .name = "f2", .shift = false, .ctrl = false },
    .{ .code = "[13~", .name = "f3", .shift = false, .ctrl = false },
    .{ .code = "[14~", .name = "f4", .shift = false, .ctrl = false },
    .{ .code = "[[A", .name = "f1", .shift = false, .ctrl = false },
    .{ .code = "[[B", .name = "f2", .shift = false, .ctrl = false },
    .{ .code = "[[C", .name = "f3", .shift = false, .ctrl = false },
    .{ .code = "[[D", .name = "f4", .shift = false, .ctrl = false },
    .{ .code = "[[E", .name = "f5", .shift = false, .ctrl = false },
    .{ .code = "[15~", .name = "f5", .shift = false, .ctrl = false },
    .{ .code = "[17~", .name = "f6", .shift = false, .ctrl = false },
    .{ .code = "[18~", .name = "f7", .shift = false, .ctrl = false },
    .{ .code = "[19~", .name = "f8", .shift = false, .ctrl = false },
    .{ .code = "[20~", .name = "f9", .shift = false, .ctrl = false },
    .{ .code = "[21~", .name = "f10", .shift = false, .ctrl = false },
    .{ .code = "[23~", .name = "f11", .shift = false, .ctrl = false },
    .{ .code = "[24~", .name = "f12", .shift = false, .ctrl = false },
    .{ .code = "[A", .name = "up", .shift = false, .ctrl = false },
    .{ .code = "[B", .name = "down", .shift = false, .ctrl = false },
    .{ .code = "[C", .name = "right", .shift = false, .ctrl = false },
    .{ .code = "[D", .name = "left", .shift = false, .ctrl = false },
    .{ .code = "[E", .name = "clear", .shift = false, .ctrl = false },
    .{ .code = "[F", .name = "end", .shift = false, .ctrl = false },
    .{ .code = "[H", .name = "home", .shift = false, .ctrl = false },
    .{ .code = "OA", .name = "up", .shift = false, .ctrl = false },
    .{ .code = "OB", .name = "down", .shift = false, .ctrl = false },
    .{ .code = "OC", .name = "right", .shift = false, .ctrl = false },
    .{ .code = "OD", .name = "left", .shift = false, .ctrl = false },
    .{ .code = "OE", .name = "clear", .shift = false, .ctrl = false },
    .{ .code = "OF", .name = "end", .shift = false, .ctrl = false },
    .{ .code = "OH", .name = "home", .shift = false, .ctrl = false },
    .{ .code = "[1~", .name = "home", .shift = false, .ctrl = false },
    .{ .code = "[2~", .name = "insert", .shift = false, .ctrl = false },
    .{ .code = "[3~", .name = "delete", .shift = false, .ctrl = false },
    .{ .code = "[4~", .name = "end", .shift = false, .ctrl = false },
    .{ .code = "[5~", .name = "pageup", .shift = false, .ctrl = false },
    .{ .code = "[6~", .name = "pagedown", .shift = false, .ctrl = false },
    .{ .code = "[[5~", .name = "pageup", .shift = false, .ctrl = false },
    .{ .code = "[[6~", .name = "pagedown", .shift = false, .ctrl = false },
    .{ .code = "[7~", .name = "home", .shift = false, .ctrl = false },
    .{ .code = "[8~", .name = "end", .shift = false, .ctrl = false },
    .{ .code = "[a", .name = "up", .shift = true, .ctrl = false },
    .{ .code = "[b", .name = "down", .shift = true, .ctrl = false },
    .{ .code = "[c", .name = "right", .shift = true, .ctrl = false },
    .{ .code = "[d", .name = "left", .shift = true, .ctrl = false },
    .{ .code = "[e", .name = "clear", .shift = true, .ctrl = false },
    .{ .code = "[2$", .name = "insert", .shift = true, .ctrl = false },
    .{ .code = "[3$", .name = "delete", .shift = true, .ctrl = false },
    .{ .code = "[5$", .name = "pageup", .shift = true, .ctrl = false },
    .{ .code = "[6$", .name = "pagedown", .shift = true, .ctrl = false },
    .{ .code = "[7$", .name = "home", .shift = true, .ctrl = false },
    .{ .code = "[8$", .name = "end", .shift = true, .ctrl = false },
    .{ .code = "Oa", .name = "up", .shift = false, .ctrl = true },
    .{ .code = "Ob", .name = "down", .shift = false, .ctrl = true },
    .{ .code = "Oc", .name = "right", .shift = false, .ctrl = true },
    .{ .code = "Od", .name = "left", .shift = false, .ctrl = true },
    .{ .code = "Oe", .name = "clear", .shift = false, .ctrl = true },
    .{ .code = "[2^", .name = "insert", .shift = false, .ctrl = true },
    .{ .code = "[3^", .name = "delete", .shift = false, .ctrl = true },
    .{ .code = "[5^", .name = "pageup", .shift = false, .ctrl = true },
    .{ .code = "[6^", .name = "pagedown", .shift = false, .ctrl = true },
    .{ .code = "[7^", .name = "home", .shift = false, .ctrl = true },
    .{ .code = "[8^", .name = "end", .shift = false, .ctrl = true },
    .{ .code = "[Z", .name = "tab", .shift = true, .ctrl = false },
};

//
// The names of the control characters \x00 to \x1a (`String.fromCharCode(code + 'a' - 1)`).
//
const control_names = [_][]const u8{ "`", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z" };

//
// The lower-case names of the letters and digits.
//
const alphanumeric_names = "0123456789abcdefghijklmnopqrstuvwxyz";

//
// Gets the key name of an alphanumeric character (its lower-case form).
//
fn alphanumericName(character: u8) []const u8 {
    const lower = std.ascii.toLower(character);
    const index = std.mem.indexOfScalar(u8, alphanumeric_names, lower).?;
    return alphanumeric_names[index .. index + 1];
}

//
// True when the character is a single ASCII digit.
//
fn isDigit(character: []const u8) bool {
    return character.len == 1 and std.ascii.isDigit(character[0]);
}

//
// Parses the modifier and code of a CSI command (the two regular expressions in emitKeys).
// Returns false when the command matches neither.
//
fn parseCsiCommand(cmd: []const u8, code: *std.ArrayList(u8), allocator: std.mem.Allocator, modifier: *u32) !bool {
    // /^(?:(\d\d?)(?:;(\d))?([~^$])|(\d{3}~))$/
    if (cmd.len == 4 and std.ascii.isDigit(cmd[0]) and std.ascii.isDigit(cmd[1]) and std.ascii.isDigit(cmd[2]) and cmd[3] == '~') {
        try code.appendSlice(allocator, cmd);
        return true;
    }
    var index: usize = 0;
    while (index < cmd.len and index < 2 and std.ascii.isDigit(cmd[index])) {
        index += 1;
    }
    if (index > 0) {
        const number = cmd[0..index];
        var modifier_digit: ?u8 = null;
        var rest = cmd[index..];
        if (rest.len >= 2 and rest[0] == ';' and std.ascii.isDigit(rest[1])) {
            modifier_digit = rest[1];
            rest = rest[2..];
        }
        if (rest.len == 1 and (rest[0] == '~' or rest[0] == '^' or rest[0] == '$')) {
            try code.appendSlice(allocator, number);
            try code.append(allocator, rest[0]);
            modifier.* = if (modifier_digit) |digit| digit - '0' - 1 else 0;
            return true;
        }
    }

    // /^((\d;)?(\d))?([A-Za-z])$/
    if (cmd.len >= 1 and std.ascii.isAlphabetic(cmd[cmd.len - 1])) {
        const prefix = cmd[0 .. cmd.len - 1];
        var modifier_text: ?u8 = null;
        var matched = false;
        if (prefix.len == 0) {
            matched = true;
        }
        else if (prefix.len == 1 and std.ascii.isDigit(prefix[0])) {
            modifier_text = prefix[0];
            matched = true;
        }
        else if (prefix.len == 3 and std.ascii.isDigit(prefix[0]) and prefix[1] == ';' and std.ascii.isDigit(prefix[2])) {
            modifier_text = prefix[2];
            matched = true;
        }
        if (matched) {
            try code.append(allocator, cmd[cmd.len - 1]);
            modifier.* = if (modifier_text) |digit| digit - '0' - 1 else 0;
            return true;
        }
    }
    return false;
}

//
// The result of parsing one keypress.
//
pub const ParseResult = struct {
    // The keypress, or null when the characters do not produce an event.
    keypress: ?Keypress,

    // The number of bytes consumed.
    length: usize,
};

//
// Parses the keypress at the start of `bytes` (node's emitKeys generator for one key).
// When `complete` is false and the bytes end in the middle of an escape sequence, returns null so that the
// caller can wait for more input; when true, missing characters read as "" (the escape timeout).
// The strings of the result point into `bytes` or static memory, except the sequence (allocated).
//
pub fn parseKeypress(allocator: std.mem.Allocator, bytes: []const u8, complete: bool) !?ParseResult {
    var reader = CharacterReader{ .bytes = bytes, .position = 0, .exhausted = false };
    var ch = reader.next();
    var escaped = false;
    var key = Key{ .sequence = "", .name = null, .ctrl = false, .meta = false, .shift = false };

    if (std.mem.eql(u8, ch, kEscape)) {
        escaped = true;
        ch = reader.next();
        if (std.mem.eql(u8, ch, kEscape)) {
            ch = reader.next();
        }
    }

    if (escaped and (std.mem.eql(u8, ch, "O") or std.mem.eql(u8, ch, "["))) {
        // ANSI escape sequence
        var code: std.ArrayList(u8) = .empty;
        try code.appendSlice(allocator, ch);
        var modifier: u32 = 0;

        if (std.mem.eql(u8, ch, "O")) {
            // ESC O letter
            // ESC O modifier letter
            ch = reader.next();
            if (isDigit(ch)) {
                modifier = ch[0] - '0' -| 1;
                ch = reader.next();
            }
            try code.appendSlice(allocator, ch);
        }
        else {
            // ESC [ letter
            // ESC [ modifier letter
            // ESC [ [ modifier letter
            // ESC [ [ num char
            ch = reader.next();
            if (std.mem.eql(u8, ch, "[")) {
                try code.appendSlice(allocator, ch);
                ch = reader.next();
            }
            const cmdStart = reader.position - ch.len;
            if (isDigit(ch)) {
                ch = reader.next();
                if (isDigit(ch)) {
                    ch = reader.next();
                    if (isDigit(ch)) {
                        ch = reader.next();
                    }
                }
            }
            if (std.mem.eql(u8, ch, ";")) {
                ch = reader.next();
                if (isDigit(ch)) {
                    ch = reader.next();
                }
            }
            const cmd = bytes[cmdStart..reader.position];
            if (!try parseCsiCommand(cmd, &code, allocator, &modifier)) {
                try code.appendSlice(allocator, cmd);
            }
        }

        if (reader.exhausted and !complete) {
            return null;
        }

        key.ctrl = (modifier & 4) != 0;
        key.meta = (modifier & 10) != 0;
        key.shift = (modifier & 1) != 0;

        for (code_names) |entry| {
            if (std.mem.eql(u8, entry.code, code.items)) {
                key.name = entry.name;
                if (entry.shift) {
                    key.shift = true;
                }
                if (entry.ctrl) {
                    key.ctrl = true;
                }
                break;
            }
        }
        if (key.name == null) {
            key.name = "undefined";
        }
    }
    else {
        if (reader.exhausted and !complete) {
            return null;
        }
        if (std.mem.eql(u8, ch, "\r")) {
            key.name = "return";
            key.meta = escaped;
        }
        else if (std.mem.eql(u8, ch, "\n")) {
            key.name = "enter";
            key.meta = escaped;
        }
        else if (std.mem.eql(u8, ch, "\t")) {
            key.name = "tab";
            key.meta = escaped;
        }
        else if (std.mem.eql(u8, ch, "\x08") or std.mem.eql(u8, ch, "\x7f")) {
            // backspace or ctrl+h
            key.name = "backspace";
            key.meta = escaped;
        }
        else if (std.mem.eql(u8, ch, kEscape)) {
            // escape key
            key.name = "escape";
            key.meta = escaped;
        }
        else if (std.mem.eql(u8, ch, " ")) {
            key.name = "space";
            key.meta = escaped;
        }
        else if (!escaped and ch.len == 1 and ch[0] <= 0x1a) {
            // ctrl+letter
            key.name = control_names[ch[0]];
            key.ctrl = true;
        }
        else if (ch.len == 1 and std.ascii.isAlphanumeric(ch[0])) {
            // Letter, number, shift+letter
            key.name = alphanumericName(ch[0]);
            key.shift = std.ascii.isUpper(ch[0]);
            key.meta = escaped;
        }
        else if (escaped) {
            // Escape sequence timeout
            key.name = if (ch.len > 0) null else "escape";
            key.meta = true;
        }
    }

    const sequence = bytes[0..reader.position];
    key.sequence = try allocator.dupe(u8, sequence);
    if (sequence.len != 0 and (key.name != null or escaped)) {
        return .{ .keypress = .{ .char = if (escaped) null else key.sequence, .key = key }, .length = sequence.len };
    }
    if (sequence.len != 0 and string_width.decodeAt(sequence, 0).length == sequence.len) {
        return .{ .keypress = .{ .char = key.sequence, .key = key }, .length = sequence.len };
    }
    return .{ .keypress = null, .length = @max(sequence.len, 1) };
}

//
// True for word characters (the regular expression class \w).
//
fn isWordCharacter(character: u8) bool {
    return std.ascii.isAlphanumeric(character) or character == '_';
}

//
// True for white space characters (the regular expression class \s, ASCII subset).
//
fn isSpaceCharacter(character: u8) bool {
    return character == ' ' or character == '\t' or character == '\n' or character == '\r' or character == 0x0b or character == 0x0c;
}

//
// The delay within which an "enter" after a "return" is ignored (readline's default crlfDelay).
//
const crlf_delay_ms = 100;

//
// The current time on the monotonic clock in milliseconds (`Date.now()` for crlfDelay).
//
fn nowMilliseconds() i64 {
    return std.Io.Clock.awake.now(std.Options.debug_io).toMilliseconds();
}

//
// The line editing state of a terminal `readline.Interface` created without an output.
//
pub const Interface = struct {
    // Allocator for the line.
    allocator: std.mem.Allocator,

    // The text of the current line (`rl.line`).
    line: std.ArrayList(u8),

    // The cursor position in the line, in bytes (`rl.cursor`).
    cursor: usize,

    // When return was last pressed (milliseconds), or null: an "enter" within crlfDelay (100ms) after it
    // is the \n of \r\n and is ignored (kSawReturnAt).
    sawReturnAt: ?i64,

    // True once the interface has been closed.
    closed: bool,

    //
    // Creates an interface with an empty line (`readline.createInterface`).
    //
    pub fn init(allocator: std.mem.Allocator) Interface {
        return .{
            .allocator = allocator,
            .line = .empty,
            .cursor = 0,
            .sawReturnAt = null,
            .closed = false,
        };
    }

    //
    // Closes the interface (`rl.close()`).
    //
    pub fn close(self: *Interface) void {
        self.closed = true;
    }

    //
    // Simulates typing: inserts data, or processes the key when data is null (`rl.write(data, key)`).
    //
    pub fn write(self: *Interface, data: ?[]const u8, key: ?Key) !void {
        const actual_key = key orelse Key{ .sequence = "", .name = null, .ctrl = false, .meta = false, .shift = false };
        try self.ttyWrite(data, actual_key);
    }

    //
    // The length in bytes of the character before the cursor.
    //
    fn previousCharacterLength(self: *Interface) usize {
        if (self.cursor == 0) {
            return 0;
        }
        var start = self.cursor - 1;
        while (start > 0 and (self.line.items[start] & 0xC0) == 0x80) {
            start -= 1;
        }
        return self.cursor - start;
    }

    //
    // The length in bytes of the character at the cursor.
    //
    fn nextCharacterLength(self: *Interface) usize {
        if (self.cursor >= self.line.items.len) {
            return 0;
        }
        return string_width.decodeAt(self.line.items, self.cursor).length;
    }

    //
    // Inserts text at the cursor (`kInsertString`).
    //
    fn insertString(self: *Interface, text: []const u8) !void {
        try self.line.insertSlice(self.allocator, self.cursor, text);
        self.cursor += text.len;
    }

    //
    // Deletes the character before the cursor (`kDeleteLeft`).
    //
    fn deleteLeft(self: *Interface) void {
        const length = self.previousCharacterLength();
        if (length == 0) {
            return;
        }
        self.line.replaceRangeAssumeCapacity(self.cursor - length, length, "");
        self.cursor -= length;
    }

    //
    // Deletes the character at the cursor (`kDeleteRight`).
    //
    fn deleteRight(self: *Interface) void {
        const length = self.nextCharacterLength();
        if (length == 0) {
            return;
        }
        self.line.replaceRangeAssumeCapacity(self.cursor, length, "");
    }

    //
    // Length of the word before the cursor (`/^\s*(?:[^\w\s]+|\w+)?/` on the reversed leading text).
    //
    fn wordLeftLength(self: *Interface) usize {
        var position = self.cursor;
        while (position > 0 and isSpaceCharacter(self.line.items[position - 1])) {
            position -= 1;
        }
        if (position > 0 and isWordCharacter(self.line.items[position - 1])) {
            while (position > 0 and isWordCharacter(self.line.items[position - 1])) {
                position -= 1;
            }
        }
        else {
            while (position > 0 and !isWordCharacter(self.line.items[position - 1]) and !isSpaceCharacter(self.line.items[position - 1])) {
                position -= 1;
            }
        }
        return self.cursor - position;
    }

    //
    // Length of the word after the cursor (`/^(?:\s+|[^\w\s]+|\w+)\s*/`).
    //
    fn wordRightLength(self: *Interface) usize {
        const items = self.line.items;
        var position = self.cursor;
        if (position < items.len and isSpaceCharacter(items[position])) {
            while (position < items.len and isSpaceCharacter(items[position])) {
                position += 1;
            }
        }
        else if (position < items.len and isWordCharacter(items[position])) {
            while (position < items.len and isWordCharacter(items[position])) {
                position += 1;
            }
        }
        else {
            while (position < items.len and !isWordCharacter(items[position]) and !isSpaceCharacter(items[position])) {
                position += 1;
            }
        }
        while (position < items.len and isSpaceCharacter(items[position])) {
            position += 1;
        }
        return position - self.cursor;
    }

    //
    // Submits the line: the line is cleared (`kLine`).
    //
    fn submitLine(self: *Interface) void {
        self.line.clearRetainingCapacity();
        self.cursor = 0;
    }

    //
    // Handles a keypress like node's `Interface[kTtyWrite]`.
    //
    pub fn ttyWrite(self: *Interface, char: ?[]const u8, key: Key) !void {

        // Ignore escape key
        if (key.name) |name| {
            if (std.mem.eql(u8, name, "escape")) {
                return;
            }
        }
        const name = key.name orelse "";

        if (key.ctrl and key.shift) {
            if (std.mem.eql(u8, name, "backspace")) {
                self.line.replaceRangeAssumeCapacity(0, self.cursor, "");
                self.cursor = 0;
            }
            else if (std.mem.eql(u8, name, "delete")) {
                self.line.shrinkRetainingCapacity(self.cursor);
            }
            return;
        }

        if (key.ctrl) {
            if (std.mem.eql(u8, name, "h")) {
                self.deleteLeft();
            }
            else if (std.mem.eql(u8, name, "d")) {
                if (self.cursor < self.line.items.len) {
                    self.deleteRight();
                }
            }
            else if (std.mem.eql(u8, name, "u")) {
                self.line.replaceRangeAssumeCapacity(0, self.cursor, "");
                self.cursor = 0;
            }
            else if (std.mem.eql(u8, name, "k")) {
                self.line.shrinkRetainingCapacity(self.cursor);
            }
            else if (std.mem.eql(u8, name, "a")) {
                self.cursor = 0;
            }
            else if (std.mem.eql(u8, name, "e")) {
                self.cursor = self.line.items.len;
            }
            else if (std.mem.eql(u8, name, "b")) {
                self.cursor -= self.previousCharacterLength();
            }
            else if (std.mem.eql(u8, name, "f")) {
                self.cursor += self.nextCharacterLength();
            }
            else if (std.mem.eql(u8, name, "w") or std.mem.eql(u8, name, "backspace")) {
                const length = self.wordLeftLength();
                self.line.replaceRangeAssumeCapacity(self.cursor - length, length, "");
                self.cursor -= length;
            }
            else if (std.mem.eql(u8, name, "delete")) {
                const length = self.wordRightLength();
                self.line.replaceRangeAssumeCapacity(self.cursor, length, "");
            }
            else if (std.mem.eql(u8, name, "left")) {
                self.cursor -= self.wordLeftLength();
            }
            else if (std.mem.eql(u8, name, "right")) {
                self.cursor += self.wordRightLength();
            }
            return;
        }

        if (key.meta) {
            if (std.mem.eql(u8, name, "b")) {
                self.cursor -= self.wordLeftLength();
            }
            else if (std.mem.eql(u8, name, "f")) {
                self.cursor += self.wordRightLength();
            }
            else if (std.mem.eql(u8, name, "d") or std.mem.eql(u8, name, "delete")) {
                const length = self.wordRightLength();
                self.line.replaceRangeAssumeCapacity(self.cursor, length, "");
            }
            else if (std.mem.eql(u8, name, "backspace")) {
                const length = self.wordLeftLength();
                self.line.replaceRangeAssumeCapacity(self.cursor - length, length, "");
                self.cursor -= length;
            }
            return;
        }

        if (std.mem.eql(u8, name, "return")) {
            self.sawReturnAt = nowMilliseconds();
            self.submitLine();
        }
        else if (std.mem.eql(u8, name, "enter")) {
            // When key interval > crlfDelay
            if (self.sawReturnAt != null and nowMilliseconds() - self.sawReturnAt.? <= crlf_delay_ms) {
                self.sawReturnAt = null;
            }
            else {
                self.submitLine();
            }
        }
        else if (std.mem.eql(u8, name, "backspace")) {
            self.deleteLeft();
        }
        else if (std.mem.eql(u8, name, "delete")) {
            self.deleteRight();
        }
        else if (std.mem.eql(u8, name, "left")) {
            self.cursor -= self.previousCharacterLength();
        }
        else if (std.mem.eql(u8, name, "right")) {
            self.cursor += self.nextCharacterLength();
        }
        else if (std.mem.eql(u8, name, "home")) {
            self.cursor = 0;
        }
        else if (std.mem.eql(u8, name, "end")) {
            self.cursor = self.line.items.len;
        }
        else if (std.mem.eql(u8, name, "up") or std.mem.eql(u8, name, "down") or std.mem.eql(u8, name, "pageup") or std.mem.eql(u8, name, "pagedown")) {
            // Not ported: history navigation (the prompts' interfaces have no history to navigate)
        }
        else {
            if (char) |text| {
                if (text.len > 0) {
                    try self.insertString(text);
                }
            }
        }
    }
};

//
// The input of a prompt (`opts.input`, default process.stdin): the bytes, and the terminal to switch to
// raw mode while a prompt reads keys.
//
pub const PromptInput = struct {
    // The source of the input bytes.
    reader: *std.Io.Reader,

    // The terminal of the input, or null when the input is not a TTY (then raw mode is not changed).
    ttyFd: ?std.posix.fd_t,

    // The terminal mode saved when raw mode was switched on, or null when raw mode is off.
    savedMode: ?std.posix.termios,

    // Allocator for the parsed key sequences.
    allocator: std.mem.Allocator,

    // True for process.stdin: at the end of the input nothing keeps the process alive, so it exits with 0
    // (the prompt promise never resolves in TypeScript). Other inputs return error.EndOfStream.
    exitAtEnd: bool,

    //
    // Creates an input that reads from a reader (a fake terminal in tests, or a TTY when ttyFd is set).
    //
    pub fn init(allocator: std.mem.Allocator, reader: *std.Io.Reader, ttyFd: ?std.posix.fd_t) PromptInput {
        return .{ .reader = reader, .ttyFd = ttyFd, .savedMode = null, .allocator = allocator, .exitAtEnd = false };
    }

    //
    // True when the input is a TTY (`input.isTTY`).
    //
    pub fn isTTY(self: *PromptInput) bool {
        return self.ttyFd != null;
    }

    //
    // Switches raw mode on or off (`input.setRawMode(value)`); does nothing when the input is not a TTY.
    //
    pub fn setRawMode(self: *PromptInput, value: bool) void {
        const fd = self.ttyFd orelse return;
        if (value) {
            if (self.savedMode == null) {
                self.savedMode = tty.enableRawMode(fd) catch null;
            }
        }
        else {
            if (self.savedMode) |mode| {
                tty.restoreMode(fd, mode);
                self.savedMode = null;
            }
        }
    }

    //
    // Waits up to the escape code timeout (50ms) for more input on the terminal. Returns true when input is ready.
    //
    fn waitForMore(self: *PromptInput) bool {
        const fd = self.ttyFd orelse return true;
        var poll_fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&poll_fds, 50) catch return false;
        return ready > 0;
    }

    //
    // Discards the rest of the chunk of input that was read last (TypeScript emits its remaining keys to
    // no listener once the prompt that was reading them has finished).
    //
    pub fn discardChunk(self: *PromptInput) void {
        self.reader.tossBuffered();
    }

    //
    // Reads the next keypress. At the end of the input, process.stdin exits the process with code 0 (the event
    // loop has nothing left to do) and other inputs return error.EndOfStream.
    //
    pub fn nextKeypress(self: *PromptInput) !Keypress {
        while (true) {
            const buffered = self.reader.buffered();
            if (buffered.len > 0) {
                if (try parseKeypress(self.allocator, buffered, false)) |result| {
                    self.reader.toss(result.length);
                    if (result.keypress) |keypress| {
                        return keypress;
                    }
                    continue;
                }

                // Incomplete escape sequence: wait for the rest, or time out.
                if (self.waitForMore()) {
                    if (self.reader.fillMore()) |_| {
                        continue;
                    }
                    else |_| {}
                }
                const result = (try parseKeypress(self.allocator, self.reader.buffered(), true)).?;
                self.reader.toss(result.length);
                if (result.keypress) |keypress| {
                    return keypress;
                }
                continue;
            }
            self.reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => {
                    if (self.exitAtEnd) {
                        self.setRawMode(false);
                        std.process.exit(0);
                    }
                    return error.EndOfStream;
                },
                else => return err,
            };
        }
    }
};
