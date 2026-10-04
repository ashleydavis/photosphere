//
// The types that cross the C interface and the types handlers are written against.
//

const std = @import("std");

//
// Delivers a JSON message from the core to the shell. The message is valid only while the call runs, so the
// shell copies it before returning. It may be called from any thread.
//
pub const DeliverFn = *const fn (user_data: ?*anyopaque, message_ptr: [*]const u8, message_len: usize) callconv(.c) void;

//
// A native host callback that writes the operating system's version string, as JSON (a JSON string), into the buffer
// the core gives it, and returns the number of bytes written, or a negative number when it cannot answer.
//
pub const OsVersionFn = *const fn (user_data: ?*anyopaque, buffer: [*]u8, capacity: usize) callconv(.c) isize;

//
// Asks the shell to quit the application. Called only by the test control connection.
//
pub const QuitFn = *const fn (user_data: ?*anyopaque) callconv(.c) void;

//
// What a shell is asked to show.
//
pub const PickKind = enum(i32) {
    // A dialog to choose one or more existing files to open.
    open_files = 0,
    // A dialog to choose where to save a file, with a suggested name.
    save_file = 1,
    // A dialog to choose a folder.
    folder = 2,
};

//
// A native host callback that shows a native file or folder dialog, waits for the user, and writes what they chose into the
// buffer the core gives it, as a JSON array of path strings ("[]" when they cancelled). Returns the number of bytes written, or
// a negative number on failure. The title is NUL terminated and may be null. The initial name is NUL terminated and may be
// null, and is used only to save. The core calls it from a worker thread, never from the one that handles page messages, so
// the shell shows the dialog on its UI thread and waits.
//
//
// A native host callback that does a menu action as if the user had chosen its menu item, by the path the menu item takes in the
// shell, so the shell's own actions (reload, zoom, developer tools, full screen, the editing commands, quit) really happen and any
// other action reaches the page. The core calls it, from the thread of the test control connection, only to let a test choose a
// menu item. The shell does the work on its UI thread and returns at once.
//
pub const MenuActionFn = *const fn (user_data: ?*anyopaque, action: [*:0]const u8) callconv(.c) void;

pub const PickPathsFn = *const fn (user_data: ?*anyopaque, kind: i32, title: ?[*:0]const u8, initial_name: ?[*:0]const u8, buffer: [*]u8, capacity: usize) callconv(.c) isize;

//
// What the shell passes to ziggy_create. Every pointer is copied by the core, so it need only be valid during the call.
// Declared with the same fields, in the same order, in ziggy.h.
//
pub const ZiggyConfig = extern struct {
    // The shell's own pointer, passed back on every callback.
    user_data: ?*anyopaque,
    // Delivers a message to the page.
    deliver: ?DeliverFn,
    // Native host callback: the operating system's version. Null when the platform has none.
    os_version: ?OsVersionFn,
    // Native host callback: quit the application. Null when the platform has none.
    quit: ?QuitFn,
    // Native host callback: show a native file or folder dialog. Null when the platform has none.
    pick_paths: ?PickPathsFn,
    // Native host callback: do a menu action as if its menu item had been chosen. Null on a platform with no menu. Used only by
    // the test control connection.
    menu_action: ?MenuActionFn,
    // The number of worker threads.
    worker_threads: u32,
    // The limit on child tasks in flight for any one parent task.
    max_concurrent_child_tasks: u32,
    // The URL prefix of the app's own bundled page, such as "file:///path/to/dist/" (NUL terminated).
    app_url_prefix: [*:0]const u8,
    // The app's private data directory (NUL terminated).
    data_dir: [*:0]const u8,
    // Non-zero to start the test control connection. Used only in a test hooks build.
    test_mode: bool,
    // The file the test control connection writes its port to, or null for none. Used only in a test hooks build.
    test_port_file: ?[*:0]const u8,
};

//
// The result of a URL check.
//
pub const UrlDecision = enum(i32) {
    // The address is the app's own page.
    allow = 0,
    // The address is an external link, to open in the system browser.
    open_externally = 1,
    // The address must not be loaded.
    block = 2,
};

//
// How a task ended.
//
pub const TaskStatus = enum {
    succeeded,
    failed,
    cancelled,
};

//
// The completion of a task, as reported to the page and to a parent that awaits it.
//
pub const Completion = struct {
    // How the task ended.
    status: TaskStatus,
    // The JSON text of the result, when it succeeded with one.
    result_json: ?[]const u8,
    // The error name, when it failed.
    error_message: ?[]const u8,
};

//
// The error a handler returns when it stops because its task was cancelled.
//
pub const TaskError = error{
    Cancelled,
    UnknownTaskType,
    HostCallbackMissing,
};
