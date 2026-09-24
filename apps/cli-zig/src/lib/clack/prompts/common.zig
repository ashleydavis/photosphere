const std = @import("std");
const builtin = @import("builtin");
const node_utils = @import("node-utils-zig");
const color = @import("../../picocolors.zig");
const tty = @import("../../tty.zig");
const readline = @import("../third-party/readline.zig");
const State = @import("../core/types.zig").ClackState;
const core_utils = @import("../core/utils/index.zig");
const PromptInput = readline.PromptInput;

//
// True when the terminal supports unicode (the `is-unicode-supported` package: on non-Windows platforms,
// every terminal except the Linux kernel console).
//
pub fn isUnicodeSupported() bool {
    if (builtin.os.tag != .windows) {
        const term = node_utils.process_env.getEnv("TERM");
        if (term) |value| {
            return !std.mem.eql(u8, value, "linux");
        }
        return true;
    }
    const env = node_utils.process_env;
    const term = env.getEnv("TERM") orelse "";
    const termProgram = env.getEnv("TERM_PROGRAM") orelse "";
    return (env.getEnv("WT_SESSION") orelse "").len > 0 or
        (env.getEnv("TERMINUS_SUBLIME") orelse "").len > 0 or
        std.mem.eql(u8, env.getEnv("ConEmuTask") orelse "", "{cmd::Cmder}") or
        std.mem.eql(u8, termProgram, "Terminus-Sublime") or
        std.mem.eql(u8, termProgram, "vscode") or
        std.mem.eql(u8, term, "xterm-256color") or
        std.mem.eql(u8, term, "alacritty") or
        std.mem.eql(u8, term, "rxvt-unicode") or
        std.mem.eql(u8, term, "rxvt-unicode-256color") or
        std.mem.eql(u8, env.getEnv("TERMINAL_EMULATOR") orelse "", "JetBrains-JediTerm");
}

//
// True when running in CI (`process.env.CI === 'true'`).
//
pub fn isCI() bool {
    return std.mem.eql(u8, node_utils.process_env.getEnv("CI") orelse "", "true");
}

//
// Returns the unicode character when unicode is supported, else the fallback.
//
pub fn unicodeOr(character: []const u8, fallback: []const u8) []const u8 {
    return if (isUnicodeSupported()) character else fallback;
}

//
// The symbols used by the prompts (TypeScript: S_* constants, computed when used).
//
pub fn S_STEP_ACTIVE() []const u8 {
    return unicodeOr("\u{25C6}", "*");
}

//
// The symbol of a cancelled prompt.
//
pub fn S_STEP_CANCEL() []const u8 {
    return unicodeOr("\u{25A0}", "x");
}

//
// The symbol of a prompt with a validation error.
//
pub fn S_STEP_ERROR() []const u8 {
    return unicodeOr("\u{25B2}", "x");
}

//
// The symbol of a submitted prompt.
//
pub fn S_STEP_SUBMIT() []const u8 {
    return unicodeOr("\u{25C7}", "o");
}

//
// The start of the bar (a space in this copy of clack).
//
pub fn S_BAR_START() []const u8 {
    return unicodeOr(" ", " ");
}

//
// The bar (a space in this copy of clack).
//
pub fn S_BAR() []const u8 {
    return unicodeOr(" ", " ");
}

//
// The end of the bar (a space in this copy of clack).
//
pub fn S_BAR_END() []const u8 {
    return unicodeOr(" ", " ");
}

//
// The symbol of the active radio option.
//
pub fn S_RADIO_ACTIVE() []const u8 {
    return unicodeOr("\u{25CF}", ">");
}

//
// The symbol of an inactive radio option.
//
pub fn S_RADIO_INACTIVE() []const u8 {
    return unicodeOr("\u{25CB}", " ");
}

//
// The password mask.
//
pub fn S_PASSWORD_MASK() []const u8 {
    return unicodeOr("\u{25AA}", "\u{2022}");
}

// Not ported: the checkbox, corner, connector and log symbols (used only by prompts that are not ported).

//
// The symbol for a prompt state, colored.
//
pub fn symbol(allocator: std.mem.Allocator, state: State) ![]const u8 {
    return switch (state) {
        .initial, .active => color.cyan(allocator, S_STEP_ACTIVE()),
        .cancel => color.red(allocator, S_STEP_CANCEL()),
        .@"error" => color.yellow(allocator, S_STEP_ERROR()),
        .submit => color.green(allocator, S_STEP_SUBMIT()),
    };
}

//
// Overrides the stdout column count seen by the prompts (used by tests); pass null to restore detection.
//
pub const setColumnsForTesting = core_utils.setColumnsForTesting;

//
// The streams of a prompt (TypeScript: `input?: Readable; output?: Writable; signal?: AbortSignal`).
// Null streams default to process.stdin and process.stdout. The AbortSignal is not ported.
//
pub const CommonOptions = struct {
    // The input stream.
    input: ?*PromptInput = null,

    // The output stream.
    output: ?*std.Io.Writer = null,
};

//
// The buffer of the process stdin reader.
//
var stdin_buffer: [4096]u8 = undefined;

//
// The process stdin reader (created on first use, shared by every prompt so no input is lost).
//
var stdin_reader: ?std.Io.File.Reader = null;

//
// The process stdin prompt input.
//
var stdin_input: PromptInput = undefined;

//
// The buffer of the process stdout writer.
//
var stdout_buffer: [4096]u8 = undefined;

//
// The process stdout writer (created on first use).
//
var stdout_writer: ?std.Io.File.Writer = null;

//
// Streams used instead of process.stdin and process.stdout when a prompt has no streams (tests only).
//
var default_streams_override: ?CommonOptions = null;

//
// Replaces the default streams of the prompts (process.stdin and process.stdout) for tests; pass null to
// restore them. This function has no TypeScript counterpart.
//
pub fn setDefaultStreamsForTesting(streams: ?CommonOptions) void {
    default_streams_override = streams;
}

//
// Gets the input stream of a prompt (process.stdin by default).
//
pub fn resolveInput(io: std.Io, options: CommonOptions) *PromptInput {
    if (options.input) |input| {
        return input;
    }
    if (default_streams_override) |streams| {
        if (streams.input) |input| {
            return input;
        }
    }
    if (stdin_reader == null) {
        stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
        const ttyFd: ?std.posix.fd_t = if (tty.isatty(tty.stdin_fd)) tty.stdin_fd else null;
        stdin_input = PromptInput.init(std.heap.smp_allocator, &stdin_reader.?.interface, ttyFd);
        stdin_input.exitAtEnd = true;
    }
    return &stdin_input;
}

//
// Gets the output stream of a prompt (process.stdout by default).
//
pub fn resolveOutput(io: std.Io, options: CommonOptions) *std.Io.Writer {
    if (options.output) |output| {
        return output;
    }
    if (default_streams_override) |streams| {
        if (streams.output) |output| {
            return output;
        }
    }
    if (stdout_writer == null) {
        stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    }
    return &stdout_writer.?.interface;
}
