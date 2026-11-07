//
// Port of the third-party `picocolors` package (v1.1.1) used by the CLI: the same color detection rules
// and the same escape sequences, including the way nested styles are re-opened after an inner close.
// The functions allocate the styled string with the caller's allocator.
//

const std = @import("std");
const builtin = @import("builtin");
const node_utils = @import("node-utils-zig");
const process_argv = @import("process-argv.zig");
const tty = @import("tty.zig");

//
// The environment, argv, platform and stdout facts that decide whether colors are used
// (picocolors reads them from `process` when it is loaded).
//
pub const IColorEnvironment = struct {
    // The value of NO_COLOR, or null when it is not set.
    NO_COLOR: ?[]const u8,

    // The value of FORCE_COLOR, or null when it is not set.
    FORCE_COLOR: ?[]const u8,

    // The value of TERM, or null when it is not set.
    TERM: ?[]const u8,

    // The value of CI, or null when it is not set.
    CI: ?[]const u8,

    // The command line arguments (process.argv).
    argv: []const []const u8,

    // True when the platform is win32.
    isWin32: bool,

    // True when stdout is a TTY.
    stdoutIsTTY: bool,
};

//
// JavaScript truthiness of an environment variable (`!!env.X`): set and not empty.
//
fn isTruthy(value: ?[]const u8) bool {
    if (value) |text| {
        return text.len > 0;
    }
    return false;
}

//
// True when argv contains the given argument (`argv.includes(argument)`).
//
fn argvIncludes(argv: []const []const u8, argument: []const u8) bool {
    for (argv) |entry| {
        if (std.mem.eql(u8, entry, argument)) {
            return true;
        }
    }
    return false;
}

//
// The picocolors detection rule:
// !(NO_COLOR || argv has --no-color) && (FORCE_COLOR || argv has --color || win32 || (stdout is a TTY && TERM !== "dumb") || CI)
//
pub fn detectColorSupport(environment: IColorEnvironment) bool {
    const disabled = isTruthy(environment.NO_COLOR) or argvIncludes(environment.argv, "--no-color");
    if (disabled) {
        return false;
    }
    const termIsDumb = if (environment.TERM) |term| std.mem.eql(u8, term, "dumb") else false;
    return isTruthy(environment.FORCE_COLOR) or
        argvIncludes(environment.argv, "--color") or
        environment.isWin32 or
        (environment.stdoutIsTTY and !termIsDumb) or
        isTruthy(environment.CI);
}

//
// The detected color support, computed on first use (picocolors computes it when loaded).
//
var detected_support: ?bool = null;

//
// Forces colors on or off (tests), or restores detection when null.
//
var support_override: ?bool = null;

//
// Forces colors on or off, or restores detection when null (used by tests).
//
pub fn setColorSupportOverride(value: ?bool) void {
    support_override = value;
}

//
// Gets the environment of this process for detectColorSupport.
//
pub fn processColorEnvironment() IColorEnvironment {
    return .{
        .NO_COLOR = node_utils.process_env.getEnv("NO_COLOR"),
        .FORCE_COLOR = node_utils.process_env.getEnv("FORCE_COLOR"),
        .TERM = node_utils.process_env.getEnv("TERM"),
        .CI = node_utils.process_env.getEnv("CI"),
        .argv = process_argv.getArgv(),
        .isWin32 = builtin.os.tag == .windows,
        .stdoutIsTTY = tty.isatty(tty.stdout_fd),
    };
}

//
// True when the default colors are enabled (picocolors `isColorSupported`).
//
pub fn isColorSupported() bool {
    if (support_override) |value| {
        return value;
    }
    if (detected_support) |value| {
        return value;
    }
    const value = detectColorSupport(processColorEnvironment());
    detected_support = value;
    return value;
}

//
// A style: the open and close sequences, and the sequence that replaces an inner close.
//
pub const Style = struct {
    // The sequence that starts the style.
    open: []const u8,

    // The sequence that ends the style.
    close: []const u8,

    // The sequence written in place of an inner occurrence of close (re-opens the style).
    replace: []const u8,
};

//
// Creates a style whose replace sequence is its open sequence (picocolors `formatter(open, close)`).
//
fn style(open: []const u8, close: []const u8) Style {
    return .{ .open = open, .close = close, .replace = open };
}

//
// Replaces every occurrence of close (starting at index) with replace
// (picocolors `replaceClose`).
//
fn replaceClose(writer: *std.Io.Writer, string: []const u8, close: []const u8, replace: []const u8, first_index: usize) std.Io.Writer.Error!void {
    var cursor: usize = 0;
    var index: ?usize = first_index;
    while (index) |found| {
        try writer.writeAll(string[cursor..found]);
        try writer.writeAll(replace);
        cursor = found + close.len;
        index = std.mem.indexOfPos(u8, string, cursor, close);
    }
    try writer.writeAll(string[cursor..]);
}

//
// Applies a style to the input (picocolors `formatter(open, close, replace)(input)`).
// Note that, like picocolors, the search for an inner close starts at offset open.length of the input.
//
pub fn format(allocator: std.mem.Allocator, styleToApply: Style, input: []const u8) std.mem.Allocator.Error![]const u8 {
    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    const writer = &allocating_writer.writer;
    const found = if (styleToApply.open.len <= input.len) std.mem.indexOfPos(u8, input, styleToApply.open.len, styleToApply.close) else null;
    if (found) |index| {
        writer.writeAll(styleToApply.open) catch return error.OutOfMemory;
        replaceClose(writer, input, styleToApply.close, styleToApply.replace, index) catch return error.OutOfMemory;
        writer.writeAll(styleToApply.close) catch return error.OutOfMemory;
    }
    else {
        writer.writeAll(styleToApply.open) catch return error.OutOfMemory;
        writer.writeAll(input) catch return error.OutOfMemory;
        writer.writeAll(styleToApply.close) catch return error.OutOfMemory;
    }
    return allocating_writer.written();
}

//
// The styles of picocolors that the CLI uses.
//
pub const styles = struct {
    // Resets all styles.
    pub const reset = Style{ .open = "\x1b[0m", .close = "\x1b[0m", .replace = "\x1b[0m" };

    // Bold text.
    pub const bold = Style{ .open = "\x1b[1m", .close = "\x1b[22m", .replace = "\x1b[22m\x1b[1m" };

    // Dim text.
    pub const dim = Style{ .open = "\x1b[2m", .close = "\x1b[22m", .replace = "\x1b[22m\x1b[2m" };

    // Italic text.
    pub const italic = style("\x1b[3m", "\x1b[23m");

    // Underlined text.
    pub const underline = style("\x1b[4m", "\x1b[24m");

    // Inverse video.
    pub const inverse = style("\x1b[7m", "\x1b[27m");

    // Hidden text.
    pub const hidden = style("\x1b[8m", "\x1b[28m");

    // Struck-through text.
    pub const strikethrough = style("\x1b[9m", "\x1b[29m");

    // Red text.
    pub const red = style("\x1b[31m", "\x1b[39m");

    // Green text.
    pub const green = style("\x1b[32m", "\x1b[39m");

    // Yellow text.
    pub const yellow = style("\x1b[33m", "\x1b[39m");

    // Blue text.
    pub const blue = style("\x1b[34m", "\x1b[39m");

    // Magenta text.
    pub const magenta = style("\x1b[35m", "\x1b[39m");

    // Cyan text.
    pub const cyan = style("\x1b[36m", "\x1b[39m");

    // White text.
    pub const white = style("\x1b[37m", "\x1b[39m");

    // Gray text.
    pub const gray = style("\x1b[90m", "\x1b[39m");
};

//
// A set of color functions that are either enabled or disabled (picocolors `createColors(enabled)`).
//
pub const Colors = struct {
    // True when the functions add escape sequences.
    isColorSupported: bool,

    //
    // Applies the style when colors are enabled, otherwise returns the input (`String(input)`).
    //
    pub fn apply(self: Colors, allocator: std.mem.Allocator, styleToApply: Style, input: []const u8) std.mem.Allocator.Error![]const u8 {
        if (!self.isColorSupported) {
            return allocator.dupe(u8, input);
        }
        return format(allocator, styleToApply, input);
    }
};

//
// Creates color functions that are enabled or disabled (picocolors `createColors`).
//
pub fn createColors(enabled: bool) Colors {
    return .{ .isColorSupported = enabled };
}

//
// The default color functions (the picocolors module export).
//
fn defaultColors() Colors {
    return createColors(isColorSupported());
}

//
// Resets all styles.
//
pub fn reset(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return defaultColors().apply(allocator, styles.reset, input);
}

//
// Bold text.
//
pub fn bold(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return defaultColors().apply(allocator, styles.bold, input);
}

//
// Dim text.
//
pub fn dim(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return defaultColors().apply(allocator, styles.dim, input);
}

//
// Italic text.
//
pub fn italic(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return defaultColors().apply(allocator, styles.italic, input);
}

//
// Underlined text.
//
pub fn underline(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return defaultColors().apply(allocator, styles.underline, input);
}

//
// Inverse video.
//
pub fn inverse(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return defaultColors().apply(allocator, styles.inverse, input);
}

//
// Hidden text.
//
pub fn hidden(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return defaultColors().apply(allocator, styles.hidden, input);
}

//
// Struck-through text.
//
pub fn strikethrough(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return defaultColors().apply(allocator, styles.strikethrough, input);
}

//
// Red text.
//
pub fn red(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return defaultColors().apply(allocator, styles.red, input);
}

//
// Green text.
//
pub fn green(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return defaultColors().apply(allocator, styles.green, input);
}

//
// Yellow text.
//
pub fn yellow(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return defaultColors().apply(allocator, styles.yellow, input);
}

//
// Blue text.
//
pub fn blue(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return defaultColors().apply(allocator, styles.blue, input);
}

//
// Magenta text.
//
pub fn magenta(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return defaultColors().apply(allocator, styles.magenta, input);
}

//
// Cyan text.
//
pub fn cyan(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return defaultColors().apply(allocator, styles.cyan, input);
}

//
// White text.
//
pub fn white(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return defaultColors().apply(allocator, styles.white, input);
}

//
// Gray text.
//
pub fn gray(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return defaultColors().apply(allocator, styles.gray, input);
}
