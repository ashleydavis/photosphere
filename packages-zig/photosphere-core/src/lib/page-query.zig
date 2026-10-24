//
// The query of the page's address: what the main process puts after the question mark when it loads the page
// (`restApiUrl`, `theme`, and `testMode=1` in test mode). The page reads all three on its
// first render, and throws without `restApiUrl`.
//

const std = @import("std");
const ziggy = @import("ziggy");
const node_api = @import("node-api-zig");
const main_state = @import("main-state.zig");

const app_config = node_api.app_config;

//
// Starts the asset server if it is not running, and gives the query the page is loaded with, with each value written percent-encoded (every character that is not a letter,
// a digit or one of -_.!~*'() becomes %XX). The address of the asset server is the loopback address and the port the operating system gave it.
// Once the query is built the main window counts as created, which starts the steps taken after the window is created
// (see MainState.mainWindowCreated).
//
// Either the asset server's port or the theme can fail to be found, and the failure reaches the native app, which does not load the
// page. The native app makes the window, so this function is where the core's side of creating the main window happens.
//
pub fn pageQuery(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, test_mode: bool) anyerror![]const u8 {
    const state = main_state.current();
    const port = try state.startAssetServer(services, io, main_state.stateAllocator());
    const theme = try app_config.getTheme(allocator, io);
    const query = try buildQuery(allocator, port, @tagName(theme), test_mode);
    try state.mainWindowCreated(services, timers, io, main_state.stateAllocator());
    return query;
}

//
// Writes the query for the asset server's port and the theme, with `testMode=1` in test mode.
//
pub fn buildQuery(allocator: std.mem.Allocator, port: u16, theme: []const u8, test_mode: bool) ![]const u8 {
    const rest_api_url = try std.fmt.allocPrint(allocator, "http://localhost:{d}", .{port});
    const test_mode_parameter: []const u8 = if (test_mode) "&testMode=1" else "";
    return std.fmt.allocPrint(allocator, "restApiUrl={s}&theme={s}{s}", .{
        try encodeUriComponent(allocator, rest_api_url),
        try encodeUriComponent(allocator, theme),
        test_mode_parameter,
    });
}

//
// Writes text as JavaScript's encodeURIComponent writes it, which is how the page's address is built and read: every byte that is not
// a letter, a digit or one of -_.!~*'() becomes %XX.
//
pub fn encodeUriComponent(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    errdefer encoded.deinit();
    try std.Uri.Component.percentEncode(&encoded.writer, raw, isUriComponentChar);
    return try encoded.toOwnedSlice();
}

//
// Whether encodeURIComponent leaves a byte as it is.
//
fn isUriComponentChar(char: u8) bool {
    return switch (char) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '!', '~', '*', '\'', '(', ')' => true,
        else => false,
    };
}
