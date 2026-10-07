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
// null: for a save dialog it is the suggested file name, and for a dialog that opens files or a folder it is the folder the dialog
// starts in, which a shell that cannot start a dialog in a folder leaves out. The core calls it from a worker thread, never from the one that handles page messages, so
// the shell shows the dialog on its UI thread and waits.
//
//
// A native host callback that does a menu action as if the user had chosen its menu item, by the path the menu item takes in the
// shell, so the shell's own actions (reload, zoom, developer tools, full screen, the editing commands, quit) really happen and any
// other action reaches the page. The core calls it, from the thread of the test control connection, only to let a test choose a
// menu item. The shell does the work on its UI thread and returns at once.
//
pub const MenuActionFn = *const fn (user_data: ?*anyopaque, action: [*:0]const u8) callconv(.c) void;

//
// Tells the shell whether the app must keep running because tasks marked keep-alive are queued or running. Called with true when the
// first such task is queued and with false when the last one ends, so the shell can use its platform's way of staying alive (an
// Android foreground service or an iOS background task; a desktop shell provides none, because closing its window quits the app). Called from any
// thread while the core holds a lock, so it must return at once and must not call back into the core.
//
pub const KeepAliveFn = *const fn (user_data: ?*anyopaque, keep_running: bool) callconv(.c) void;

pub const PickPathsFn = *const fn (user_data: ?*anyopaque, kind: i32, title: ?[*:0]const u8, initial_name: ?[*:0]const u8, buffer: [*]u8, capacity: usize) callconv(.c) isize;

//
// A native host callback that does one thing only the platform can do, named by `method` ("exportFile", "secureStoreGet", ...). The
// request is the JSON text of the method's argument (NUL terminated), and the shell writes the JSON text of its answer into the
// buffer and returns the number of bytes written. When it cannot do what was asked it writes the text of the reason, in words the user
// can act on, and returns that number of bytes negated. The shell may show native interface and wait for the user, so the core calls
// it from a worker thread, never from the one that handles page messages, and it may take a long time.
//
pub const HostRequestFn = *const fn (user_data: ?*anyopaque, method: [*:0]const u8, request_json: [*:0]const u8, buffer: [*]u8, capacity: usize) callconv(.c) isize;

//
// What a shell answered a host request with.
//
pub const HostReply = struct {
    // Whether the shell did what was asked.
    succeeded: bool,
    // The JSON text of the answer when it succeeded, and the text of the reason when it did not.
    text: []const u8,
};

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
    // Native host callback: keep the app running, or stop. Null when the platform has none.
    keep_alive: ?KeepAliveFn,
    // The number of worker threads.
    worker_threads: u32,
    // The limit on child tasks in flight for any one parent task.
    max_concurrent_child_tasks: u32,
    // The URL prefix of the app's own bundled page, such as "ziggy-app://app/" or "https://ziggy-app.invalid/", the address the shell serves the page from (NUL terminated).
    app_url_prefix: [*:0]const u8,
    // The app's private data directory (NUL terminated).
    data_dir: [*:0]const u8,
    // Non-zero to start the test control connection. Used only in a test hooks build.
    test_mode: bool,
    // The file the test control connection writes its port to, or null for none. Used only in a test hooks build.
    test_port_file: ?[*:0]const u8,
    // Native host callback: do one thing only the platform can do (a share sheet, a permission prompt, the keychain), by name. Null when
    // the platform has none. Last in the struct so that a shell that builds it with zeroes needs no change.
    host_request: ?HostRequestFn,
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

//
// A function that gives the text to report for an error a handler returned, or null to report the error's name. An app supplies
// one when its code records the reason for a failure somewhere other than the error's name, as a Zig error carries no message.
//
pub const ErrorDescriber = *const fn (err: anyerror) ?[]const u8;

//
// How a task ended, as reported to the app's observer: the task's type and input as well as its outcome, which the page's
// task-completed event does not carry on its own account (the page knows what it asked for).
//
pub const TaskEnd = struct {
    // The id of the task.
    task_id: []const u8,
    // The task type string.
    task_type: []const u8,
    // The source the task was queued under.
    source: []const u8,
    // The task's input data as JSON text.
    input_json: []const u8,
    // How the task ended.
    status: TaskStatus,
    // The text of the error, when it failed.
    error_message: ?[]const u8,
};

//
// A message a task sent, as reported to the app's observer.
//
pub const TaskSentMessage = struct {
    // The id of the task.
    task_id: []const u8,
    // The task type string.
    task_type: []const u8,
    // The source the task was queued under.
    source: []const u8,
    // The message as JSON text.
    message_json: []const u8,
};

//
// Lets the app see every task end and every message a task sends, as the Electron main process does with the worker pool's
// onTaskComplete and onAnyTaskMessage. Both functions are called from the thread the event happened on, with no lock held, and the
// values are valid only during the call.
//
pub const TaskObserver = struct {
    // The observer's own pointer, passed back on every call.
    user_data: ?*anyopaque,
    // Called when a task has ended, after the page has been told.
    on_task_end: *const fn (user_data: ?*anyopaque, end: TaskEnd) void,
    // Called when a task sends a message, after the page has been told.
    on_task_message: *const fn (user_data: ?*anyopaque, sent: TaskSentMessage) void,
};
