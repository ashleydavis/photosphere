//
// A stand-in for a shell, for the unit tests of an app built on Ziggy. It records every message the core delivers and
// answers the native host callbacks. Nothing in a shipped app uses it, so it is never compiled into one.
//

const std = @import("std");
const types = @import("types.zig");

//
// A stand-in for a shell. It records every message the core delivers, and can answer the native host callbacks.
//
pub const FakeShell = struct {
    // Allocates the recorded messages.
    allocator: std.mem.Allocator,
    // For the mutex and sleeping.
    threaded: std.Io.Threaded,
    // Guards the messages.
    mutex: std.Io.Mutex,
    // Every message delivered, in the order delivered.
    messages: std.ArrayList([]u8),
    // The menu actions chosen through the menu_action callback, one per line.
    chosen_actions: std.ArrayList(u8),
    // Set by the quit callback.
    quit_called: std.atomic.Value(bool),

    pub fn init(self: *FakeShell, allocator: std.mem.Allocator) void {
        self.* = .{
            .allocator = allocator,
            .threaded = .init_single_threaded,
            .mutex = .init,
            .messages = .empty,
            .quit_called = .init(false),
            .chosen_actions = .empty,
        };
    }

    pub fn deinit(self: *FakeShell) void {
        for (self.messages.items) |message| {
            self.allocator.free(message);
        }
        self.messages.deinit(self.allocator);
        self.chosen_actions.deinit(self.allocator);
    }

    fn io(self: *FakeShell) std.Io {
        return self.threaded.io();
    }

    pub fn deliver(user_data: ?*anyopaque, message_ptr: [*]const u8, message_len: usize) callconv(.c) void {
        const self: *FakeShell = @ptrCast(@alignCast(user_data.?));
        const copy = self.allocator.dupe(u8, message_ptr[0..message_len]) catch @panic("out of memory");
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());
        self.messages.append(self.allocator, copy) catch @panic("out of memory");
    }

    pub fn osVersion(user_data: ?*anyopaque, buffer: [*]u8, capacity: usize) callconv(.c) isize {
        _ = user_data;
        const text = "\"Test OS 1.0\"";
        if (capacity < text.len) {
            return -1;
        }
        @memcpy(buffer[0..text.len], text);
        return @intCast(text.len);
    }

    //
    // The dialog callback: answers with one fixed path for a folder, one fixed file name for a save and two files for an open, and
    // records the title and the initial name it was given so a test can check them.
    //
    pub fn pickPaths(user_data: ?*anyopaque, kind: i32, title: ?[*:0]const u8, initial_name: ?[*:0]const u8, buffer: [*]u8, capacity: usize) callconv(.c) isize {
        const self: *FakeShell = @ptrCast(@alignCast(user_data.?));
        var text_buffer: [256]u8 = undefined;
        const answer = std.fmt.bufPrint(&text_buffer, "[\"kind{d}\",\"{s}\",\"{s}\"]", .{ kind, if (title) |text| std.mem.span(text) else "-", if (initial_name) |text| std.mem.span(text) else "-" }) catch return -1;
        _ = self;
        if (capacity < answer.len) {
            return -1;
        }
        @memcpy(buffer[0..answer.len], answer);
        return @intCast(answer.len);
    }

    //
    // A dialog callback for a user who cancels: it answers with no paths.
    //
    pub fn pickNothing(user_data: ?*anyopaque, kind: i32, title: ?[*:0]const u8, initial_name: ?[*:0]const u8, buffer: [*]u8, capacity: usize) callconv(.c) isize {
        _ = user_data;
        _ = kind;
        _ = title;
        _ = initial_name;
        const answer = "[]";
        if (capacity < answer.len) {
            return -1;
        }
        @memcpy(buffer[0..answer.len], answer);
        return @intCast(answer.len);
    }

    //
    // The menu action callback: records the action chosen.
    //
    pub fn menuAction(user_data: ?*anyopaque, action: [*:0]const u8) callconv(.c) void {
        const self: *FakeShell = @ptrCast(@alignCast(user_data.?));
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());
        self.chosen_actions.appendSlice(self.allocator, std.mem.span(action)) catch @panic("out of memory");
        self.chosen_actions.append(self.allocator, '\n') catch @panic("out of memory");
    }

    pub fn quit(user_data: ?*anyopaque) callconv(.c) void {
        const self: *FakeShell = @ptrCast(@alignCast(user_data.?));
        self.quit_called.store(true, .release);
    }

    //
    // The configuration to give a core, with this shell's callbacks.
    //
    pub fn config(self: *FakeShell, worker_threads: u32, max_children: u32) types.ZiggyConfig {
        return .{
            .user_data = self,
            .deliver = deliver,
            .os_version = osVersion,
            .quit = quit,
            .pick_paths = pickPaths,
            .menu_action = menuAction,
            .worker_threads = worker_threads,
            .max_concurrent_child_tasks = max_children,
            .app_url_prefix = "file:///app/dist/",
            .data_dir = "/tmp",
            .test_mode = false,
            .test_port_file = null,
        };
    }

    //
    // The number of messages delivered so far.
    //
    pub fn count(self: *FakeShell) usize {
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());
        return self.messages.items.len;
    }

    //
    // Copies the message at the index into the allocator's memory.
    //
    pub fn messageAt(self: *FakeShell, allocator: std.mem.Allocator, index: usize) ![]u8 {
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());
        return try allocator.dupe(u8, self.messages.items[index]);
    }

    //
    // Waits until a message containing the text has been delivered, and fails the test when it takes too long.
    //
    pub fn expectMessageContaining(self: *FakeShell, text: []const u8) !void {
        var waited_ms: u32 = 0;
        while (waited_ms < 20_000) : (waited_ms += 2) {
            if (self.countContaining(text) > 0) {
                return;
            }
            self.sleepMs(2);
        }
        std.debug.print("no message containing {s}\n", .{text});
        return error.MessageNeverArrived;
    }

    //
    // The number of delivered messages that contain the text.
    //
    pub fn countContaining(self: *FakeShell, text: []const u8) usize {
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());
        var found: usize = 0;
        for (self.messages.items) |message| {
            if (std.mem.indexOf(u8, message, text) != null) {
                found += 1;
            }
        }
        return found;
    }

    //
    // The index of the first message that contains the text, or null.
    //
    pub fn indexOfContaining(self: *FakeShell, text: []const u8) ?usize {
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());
        for (self.messages.items, 0..) |message, index| {
            if (std.mem.indexOf(u8, message, text) != null) {
                return index;
            }
        }
        return null;
    }

    //
    // Sleeps, for tests that need time to pass.
    //
    pub fn sleepMs(self: *FakeShell, milliseconds: i64) void {
        self.io().sleep(.fromMilliseconds(milliseconds), .awake) catch @panic("sleep cancelled");
    }
};

//
