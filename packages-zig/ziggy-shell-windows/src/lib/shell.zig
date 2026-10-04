//
// Ziggy's Windows shell. It creates the window, hosts WebView2, injects window.ziggy, loads the app's bundled page,
// calls the core through the C interface and moves messages between the page and the core.
//
// Messages from the core arrive on any thread, so they are queued and delivered to the web view from the UI thread.
//
// WebView2 is used through its native COM interface, with the declarations translated from the SDK's own WebView2.h.
// WebView2Loader.dll is loaded from the executable's directory when the shell starts.
//

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const geometry_lib = @import("geometry.zig");
const file_url = @import("file-url.zig");
const accelerator_lib = @import("accelerator.zig");
const actions_lib = @import("actions.zig");
const menu_lib = @import("menu.zig");
const pickers_lib = @import("pickers.zig");

//
// What an app tells the shell about itself.
//
pub const AppConfig = struct {
    // The application id, which also names the app's private data directory.
    app_id: [:0]const u8,
    // The window title.
    title: [:0]const u8,
    // The window's width when the command line does not give one.
    default_width: c_int,
    // The window's height when the command line does not give one.
    default_height: c_int,
    // The script that exposes window.ziggy, run in the page before its own scripts.
    inject_script: [:0]const u8,
    // The name of the directory beside the executable that holds the app's bundled page.
    ui_directory_name: [:0]const u8,
};

//
// The window message the deliver callback posts to the UI thread to say messages are waiting in the queue.
//
const WM_ZIGGY_DELIVER: c.UINT = c.WM_APP + 1;

//
// The window message a worker thread posts to the UI thread to ask it to show a file or folder dialog. Its lparam is the
// address of the request.
//
const WM_ZIGGY_PICK: c.UINT = c.WM_APP + 2;

//
// The window message the test control connection's thread posts to ask the UI thread to do a menu action. Its lparam is the
// address of the action text, which the UI thread frees.
//
const WM_ZIGGY_MENU: c.UINT = c.WM_APP + 3;

//
// The signature of CreateCoreWebView2EnvironmentWithOptions, which is looked up in WebView2Loader.dll.
//
const CreateEnvironmentFn = *const @TypeOf(c.CreateCoreWebView2EnvironmentWithOptions);

//
// The name of the window class the shell registers.
//
const window_class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZiggyShellWindow");

//
// The window style: a normal top level window with a title bar, borders and the sizing and minimize and maximize buttons.
//
const window_style: c.DWORD = c.WS_OVERLAPPEDWINDOW;

//
// Implements the parts of IUnknown that every handler object shares. A handler lives inside the Shell, which outlives
// every call WebView2 can make to it, so it counts no references and says it always has one.
//
fn ComHandler(comptime Interface: type, comptime interface_id: c.IID) type {
    return struct {
        // The COM object WebView2 is given: a pointer to its table of functions.
        interface: Interface,
        // The shell the handler works for.
        shell: *Shell,

        fn queryInterface(this: [*c]Interface, requested: [*c]const c.IID, result: [*c]?*anyopaque) callconv(.c) c.HRESULT {
            if (result == null) {
                return c.E_POINTER;
            }
            result.* = null;
            if (requested == null) {
                return c.E_POINTER;
            }
            if (guidEquals(requested, &c.IID_IUnknown) or guidEquals(requested, &interface_id)) {
                result.* = this;
                return c.S_OK;
            }
            return c.E_NOINTERFACE;
        }

        fn addRef(this: [*c]Interface) callconv(.c) c.ULONG {
            _ = this;
            return 1;
        }

        fn release(this: [*c]Interface) callconv(.c) c.ULONG {
            _ = this;
            return 1;
        }

        fn fromInterface(this: [*c]Interface) *@This() {
            return @fieldParentPtr("interface", @as(*Interface, @ptrCast(this)));
        }
    };
}

//
// The handler object for the Environment callback, which WebView2 calls on the UI thread.
//
const EnvironmentHandler = ComHandler(c.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, c.IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler);
//
// The handler object for the Controller callback, which WebView2 calls on the UI thread.
//
const ControllerHandler = ComHandler(c.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, c.IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler);
//
// The handler object for the WebMessage callback, which WebView2 calls on the UI thread.
//
const WebMessageHandler = ComHandler(c.ICoreWebView2WebMessageReceivedEventHandler, c.IID_ICoreWebView2WebMessageReceivedEventHandler);
//
// The handler object for the Navigation callback, which WebView2 calls on the UI thread.
//
const NavigationHandler = ComHandler(c.ICoreWebView2NavigationStartingEventHandler, c.IID_ICoreWebView2NavigationStartingEventHandler);
//
// The handler object for the NewWindow callback, which WebView2 calls on the UI thread.
//
const NewWindowHandler = ComHandler(c.ICoreWebView2NewWindowRequestedEventHandler, c.IID_ICoreWebView2NewWindowRequestedEventHandler);
//
// The handler object for the ScriptAdded callback, which WebView2 calls on the UI thread.
//
const ScriptAddedHandler = ComHandler(c.ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler, c.IID_ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler);
//
// The handler object for the ScriptExecuted callback, which WebView2 calls on the UI thread.
//
const ScriptExecutedHandler = ComHandler(c.ICoreWebView2ExecuteScriptCompletedHandler, c.IID_ICoreWebView2ExecuteScriptCompletedHandler);
//
// The handler object for the AcceleratorKey callback, which WebView2 calls on the UI thread before a key press reaches the page.
//
const AcceleratorHandler = ComHandler(c.ICoreWebView2AcceleratorKeyPressedEventHandler, c.IID_ICoreWebView2AcceleratorKeyPressedEventHandler);

//
// The first command id given to a menu item. An item's id is this plus its place in the shell's list of menu actions.
//
const first_command_id: usize = 1000;

//
// The ziggy.h modifier bits are the ones accelerator.zig uses.
//
comptime {
    std.debug.assert(c.ZIGGY_MOD_CTRL == accelerator_lib.modifier_control);
    std.debug.assert(c.ZIGGY_MOD_SHIFT == accelerator_lib.modifier_shift);
    std.debug.assert(c.ZIGGY_MOD_ALT == accelerator_lib.modifier_alt);
    std.debug.assert(c.ZIGGY_MOD_META == accelerator_lib.modifier_windows);
    std.debug.assert(c.ZIGGY_PICK_OPEN_FILES == @intFromEnum(pickers_lib.PickKind.open_files));
    std.debug.assert(c.ZIGGY_PICK_SAVE_FILE == @intFromEnum(pickers_lib.PickKind.save_file));
    std.debug.assert(c.ZIGGY_PICK_FOLDER == @intFromEnum(pickers_lib.PickKind.folder));
    std.debug.assert(c.FOS_ALLOWMULTISELECT == pickers_lib.option_allow_multiselect);
    std.debug.assert(c.FOS_PICKFOLDERS == pickers_lib.option_pick_folders);
    std.debug.assert(c.FOS_FORCEFILESYSTEM == pickers_lib.option_force_file_system);
    std.debug.assert(c.FOS_PATHMUSTEXIST == pickers_lib.option_path_must_exist);
    std.debug.assert(c.FOS_FILEMUSTEXIST == pickers_lib.option_file_must_exist);
    std.debug.assert(c.FOS_OVERWRITEPROMPT == pickers_lib.option_overwrite_prompt);
}

//
// One menu item that does something: what it does and the shortcut that does it.
//
const MenuAction = struct {
    // The action name from the menu. Owned.
    action: []u8,
    // The keyboard shortcut, or null for none.
    binding: ?accelerator_lib.Binding,
};

//
// Everything one running shell owns. It lives on the stack of run and every callback is given its address.
//
const Shell = struct {
    // What the app asked for.
    app_config: AppConfig,
    // The command line, for the geometry option.
    args: []const [:0]const u8,
    // The top level window.
    window: c.HWND,
    // The WebView2 controller, once it exists. Owned.
    controller: ?*c.ICoreWebView2Controller,
    // The web view, once it exists. Owned.
    web_view: ?*c.ICoreWebView2,
    // The core's handle, until it is destroyed.
    core: ?*anyopaque,
    // Guards the queue.
    queue_lock: c.SRWLOCK,
    // Messages from the core waiting for the UI thread, oldest first. Every text is owned by the queue.
    queue: std.ArrayList([]u8),
    // Set when the core has been destroyed, so nothing more is delivered.
    destroyed: std.atomic.Value(bool),
    // Set on the UI thread when the window starts closing, so the creation callbacks still to come do nothing.
    closing: bool,
    // The URL prefix of the app's bundled page, with a trailing slash. Owned.
    app_url_prefix: [:0]u8,
    // The page's address as UTF-16, including the query in test mode. Owned.
    page_url: [:0]u16,
    // The script that exposes window.ziggy, as UTF-16. Owned.
    inject_script: [:0]u16,
    // The directory of the app's private data. Owned.
    data_directory: [:0]u8,
    // Whether a test hooks build was started in test mode.
    test_mode: bool,
    // The file the test control connection writes its port to, from the environment, in test mode. Owned.
    test_port_file: ?[:0]u8,
    // Receives the WebView2 environment.
    environment_handler: EnvironmentHandler,
    // Receives the WebView2 controller.
    controller_handler: ControllerHandler,
    // Receives messages posted by the page.
    web_message_handler: WebMessageHandler,
    // Receives the start of every navigation.
    navigation_handler: NavigationHandler,
    // Receives every request to open a new window.
    new_window_handler: NewWindowHandler,
    // Receives the result of adding the injected script.
    script_added_handler: ScriptAddedHandler,
    // The menu items that do something, in command id order. Every action is owned.
    menu_actions: std.ArrayList(MenuAction),
    // The menu bar, or null when the app has no menu. Windows destroys it with the window.
    menu_bar: c.HMENU,
    // The shortcuts of the menu as a table for the message loop, or null for none. Owned.
    accelerator_table: c.HACCEL,
    // True while the window is full screen.
    fullscreen: bool,
    // Where the window was before it went full screen.
    saved_placement: c.WINDOWPLACEMENT,
    // Receives the keys pressed inside the web view before the page sees them.
    accelerator_handler: AcceleratorHandler,
    // Receives the selected text a copy asked the page for.
    copy_handler: ScriptExecutedHandler,
    // Receives the selected text a cut asked the page for.
    cut_handler: ScriptExecutedHandler,
    // Receives the result of running a script that delivers a message.
    script_executed_handler: ScriptExecutedHandler,
};

//
// Runs the app and returns the process's exit code.
//
pub fn run(app_config: AppConfig, args: []const [:0]const u8) !u8 {
    const allocator = std.heap.c_allocator;
    var shell: Shell = .{
        .app_config = app_config,
        .args = args,
        .window = null,
        .controller = null,
        .web_view = null,
        .core = null,
        .queue_lock = std.mem.zeroes(c.SRWLOCK),
        .queue = .empty,
        .destroyed = .init(false),
        .closing = false,
        .app_url_prefix = undefined,
        .page_url = undefined,
        .inject_script = undefined,
        .data_directory = undefined,
        .test_mode = false,
        .test_port_file = null,
        .menu_actions = .empty,
        .menu_bar = null,
        .accelerator_table = null,
        .fullscreen = false,
        .saved_placement = std.mem.zeroes(c.WINDOWPLACEMENT),
        .accelerator_handler = undefined,
        .copy_handler = undefined,
        .cut_handler = undefined,
        .environment_handler = undefined,
        .controller_handler = undefined,
        .web_message_handler = undefined,
        .navigation_handler = undefined,
        .new_window_handler = undefined,
        .script_added_handler = undefined,
        .script_executed_handler = undefined,
    };
    initHandlers(&shell);
    const exit_code = try start(&shell, allocator);
    destroyCore(&shell);
    discardPending(&shell, allocator);
    for (shell.menu_actions.items) |menu_action| {
        allocator.free(menu_action.action);
    }
    shell.menu_actions.deinit(allocator);
    if (shell.accelerator_table != null) {
        _ = c.DestroyAcceleratorTable(shell.accelerator_table);
    }
    shell.queue.deinit(allocator);
    return exit_code;
}

//
// Prints the reason and ends the process with a failure code.
//
fn fatal(comptime format: []const u8, arguments: anytype) noreturn {
    std.debug.print("ziggy shell: " ++ format ++ "\n", arguments);
    std.process.exit(1);
}

//
// Stops the process when a WebView2 or Win32 call failed.
//
fn check(what: []const u8, result: c.HRESULT) void {
    if (result < 0) {
        fatal("{s} failed with HRESULT 0x{X:0>8}", .{ what, @as(u32, @bitCast(result)) });
    }
}

fn guidEquals(left: *const c.GUID, right: *const c.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(left), std.mem.asBytes(right));
}

//
// Points every handler's COM object at its table of functions and at the shell.
//
fn initHandlers(shell: *Shell) void {
    shell.environment_handler = .{
        .interface = .{
            .lpVtbl = @constCast(&environment_vtable),
        },
        .shell = shell,
    };
    shell.controller_handler = .{
        .interface = .{
            .lpVtbl = @constCast(&controller_vtable),
        },
        .shell = shell,
    };
    shell.web_message_handler = .{
        .interface = .{
            .lpVtbl = @constCast(&web_message_vtable),
        },
        .shell = shell,
    };
    shell.navigation_handler = .{
        .interface = .{
            .lpVtbl = @constCast(&navigation_vtable),
        },
        .shell = shell,
    };
    shell.new_window_handler = .{
        .interface = .{
            .lpVtbl = @constCast(&new_window_vtable),
        },
        .shell = shell,
    };
    shell.script_added_handler = .{
        .interface = .{
            .lpVtbl = @constCast(&script_added_vtable),
        },
        .shell = shell,
    };
    shell.accelerator_handler = .{
        .interface = .{
            .lpVtbl = @constCast(&accelerator_vtable),
        },
        .shell = shell,
    };
    shell.copy_handler = .{
        .interface = .{
            .lpVtbl = @constCast(&copy_vtable),
        },
        .shell = shell,
    };
    shell.cut_handler = .{
        .interface = .{
            .lpVtbl = @constCast(&cut_vtable),
        },
        .shell = shell,
    };
    shell.script_executed_handler = .{
        .interface = .{
            .lpVtbl = @constCast(&script_executed_vtable),
        },
        .shell = shell,
    };
}

//
// Reads an environment variable as UTF-8, or null when it is not set. The caller owns the result.
//
fn readEnvironment(allocator: std.mem.Allocator, comptime name: []const u8) !?[:0]u8 {
    const wide_name = comptime std.unicode.utf8ToUtf16LeStringLiteral(name);
    var buffer: [4096]u16 = undefined;
    const length = c.GetEnvironmentVariableW(wide_name.ptr, &buffer, buffer.len);
    if (length == 0) {
        if (c.GetLastError() == c.ERROR_ENVVAR_NOT_FOUND) {
            return null;
        }
        return error.EnvironmentReadFailed;
    }
    if (length >= buffer.len) {
        return error.EnvironmentValueTooLong;
    }
    return try std.unicode.utf16LeToUtf8AllocZ(allocator, buffer[0..length]);
}

//
// Reads the path of the running executable as UTF-8. The caller owns the result.
//
fn executablePath(allocator: std.mem.Allocator) ![:0]u8 {
    var buffer: [32768]u16 = undefined;
    const length = c.GetModuleFileNameW(null, &buffer, buffer.len);
    if (length == 0 or length >= buffer.len) {
        return error.ExecutablePathUnknown;
    }
    return try std.unicode.utf16LeToUtf8AllocZ(allocator, buffer[0..length]);
}

//
// Creates the window, starts WebView2 and runs the message loop until the window closes.
//
fn start(shell: *Shell, allocator: std.mem.Allocator) !u8 {
    const test_hooks = c.ziggy_test_hooks_enabled();
    shell.test_mode = false;
    if (test_hooks) {
        const test_mode = try readEnvironment(allocator, "ZIGGY_TEST_MODE");
        shell.test_mode = test_mode != null;
    }

    const executable = try executablePath(allocator);
    defer allocator.free(executable);
    const executable_directory = std.fs.path.dirnameWindows(executable) orelse {
        return error.ExecutablePathUnknown;
    };
    const ui_directory = try std.fmt.allocPrint(allocator, "{s}\\{s}", .{ executable_directory, shell.app_config.ui_directory_name });
    defer allocator.free(ui_directory);
    shell.app_url_prefix = try file_url.directoryFileUrl(allocator, ui_directory);
    const query: []const u8 = if (shell.test_mode) "?testMode=1" else "";
    const page_url_utf8 = try std.fmt.allocPrint(allocator, "{s}index.html{s}", .{ shell.app_url_prefix, query });
    defer allocator.free(page_url_utf8);
    shell.page_url = try std.unicode.utf8ToUtf16LeAllocZ(allocator, page_url_utf8);
    shell.inject_script = try std.unicode.utf8ToUtf16LeAllocZ(allocator, shell.app_config.inject_script);

    const local_app_data = try readEnvironment(allocator, "LOCALAPPDATA") orelse {
        return error.LocalAppDataMissing;
    };
    defer allocator.free(local_app_data);
    shell.data_directory = try std.fmt.allocPrintSentinel(allocator, "{s}\\{s}", .{ local_app_data, shell.app_config.app_id }, 0);
    const wide_data_directory = try std.unicode.utf8ToUtf16LeAllocZ(allocator, shell.data_directory);
    defer allocator.free(wide_data_directory);
    const created = c.SHCreateDirectoryExW(null, wide_data_directory.ptr, null);
    if (created != c.ERROR_SUCCESS and created != c.ERROR_ALREADY_EXISTS) {
        return error.DataDirectoryFailed;
    }
    const user_data_folder = try std.fmt.allocPrint(allocator, "{s}\\WebView2", .{shell.data_directory});
    defer allocator.free(user_data_folder);
    const wide_user_data_folder = try std.unicode.utf8ToUtf16LeAllocZ(allocator, user_data_folder);
    defer allocator.free(wide_user_data_folder);

    if (shell.test_mode) {
        shell.test_port_file = try readEnvironment(allocator, "ZIGGY_TEST_PORT_FILE");
    }

    var width = shell.app_config.default_width;
    var height = shell.app_config.default_height;
    var left: c_int = std.math.minInt(c_int);
    var top: c_int = std.math.minInt(c_int);
    for (shell.args) |argument| {
        if (std.mem.startsWith(u8, argument, "-geometry=")) {
            const geometry = geometry_lib.parseGeometry(argument["-geometry=".len..]) orelse {
                return error.InvalidGeometry;
            };
            width = geometry.width;
            height = geometry.height;
            if (geometry.x) |x| {
                left = x;
            }
            if (geometry.y) |y| {
                top = y;
            }
        }
    }

    // Without this Windows scales the window as a bitmap on a high resolution screen and the page looks blurred.
    if (c.SetProcessDpiAwarenessContext(c.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) == 0) {
        std.debug.print("ziggy shell: could not set per monitor DPI awareness, error {d}\n", .{c.GetLastError()});
    }

    const hr_init = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    check("CoInitializeEx", hr_init);
    defer c.CoUninitialize();

    const instance = c.GetModuleHandleW(null);
    var window_class = std.mem.zeroes(c.WNDCLASSEXW);
    window_class.cbSize = @sizeOf(c.WNDCLASSEXW);
    window_class.lpfnWndProc = windowProc;
    window_class.hInstance = instance;
    // IDC_ARROW, the standard arrow, which the resource macro MAKEINTRESOURCE would write as 32512.
    window_class.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    window_class.lpszClassName = window_class_name.ptr;
    if (c.RegisterClassExW(&window_class) == 0) {
        return error.WindowClassFailed;
    }

    // The size the command line gives is the size of the page, and a pixel here is a pixel at 96 DPI.
    const dpi = c.GetDpiForSystem();
    var frame = c.RECT{
        .left = 0,
        .top = 0,
        .right = @divTrunc(width * @as(c_int, @intCast(dpi)), 96),
        .bottom = @divTrunc(height * @as(c_int, @intCast(dpi)), 96),
    };
    if (c.AdjustWindowRectExForDpi(&frame, window_style, 0, 0, dpi) == 0) {
        return error.WindowSizeFailed;
    }
    const wide_title = try std.unicode.utf8ToUtf16LeAllocZ(allocator, shell.app_config.title);
    defer allocator.free(wide_title);
    shell.window = c.CreateWindowExW(
        0,
        window_class_name.ptr,
        wide_title.ptr,
        window_style,
        left,
        top,
        frame.right - frame.left,
        frame.bottom - frame.top,
        null,
        null,
        instance,
        shell,
    ) orelse {
        return error.WindowCreateFailed;
    };
    _ = c.ShowWindow(shell.window, c.SW_SHOW);
    if (c.UpdateWindow(shell.window) == 0) {
        return error.WindowCreateFailed;
    }

    const loader = c.LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("WebView2Loader.dll"), null, c.LOAD_LIBRARY_SEARCH_APPLICATION_DIR) orelse {
        std.debug.print("ziggy shell: WebView2Loader.dll could not be loaded from the executable's directory, error {d}\n", .{c.GetLastError()});
        return error.WebView2LoaderMissing;
    };
    const create_address = c.GetProcAddress(loader, "CreateCoreWebView2EnvironmentWithOptions") orelse {
        return error.WebView2LoaderInvalid;
    };
    const create_environment: CreateEnvironmentFn = @ptrCast(create_address);
    check("CreateCoreWebView2EnvironmentWithOptions", create_environment(null, wide_user_data_folder.ptr, null, &shell.environment_handler.interface));

    var message: c.MSG = undefined;
    while (true) {
        const result = c.GetMessageW(&message, null, 0, 0);
        if (result == 0) {
            break;
        }
        if (result < 0) {
            return error.MessageLoopFailed;
        }
        if (shell.accelerator_table != null and c.TranslateAcceleratorW(shell.window, shell.accelerator_table, &message) != 0) {
            continue;
        }
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
    return @intCast(message.wParam & 0xFF);
}

fn shellOf(window: c.HWND) ?*Shell {
    const value = c.GetWindowLongPtrW(window, c.GWLP_USERDATA);
    if (value == 0) {
        return null;
    }
    return @ptrFromInt(@as(usize, @intCast(value)));
}

//
// The window procedure: sizes the web view with the window, delivers queued messages and closes everything in order.
//
fn windowProc(window: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (message == c.WM_NCCREATE) {
        const create: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @intCast(lparam)));
        _ = c.SetWindowLongPtrW(window, c.GWLP_USERDATA, @intCast(@intFromPtr(create.lpCreateParams)));
        return c.DefWindowProcW(window, message, wparam, lparam);
    }
    const shell = shellOf(window) orelse {
        return c.DefWindowProcW(window, message, wparam, lparam);
    };
    switch (message) {
        c.WM_SIZE => {
            resizeWebView(shell);
            return 0;
        },
        c.WM_MOVE => {
            if (shell.controller) |controller| {
                check("NotifyParentWindowPositionChanged", controller.lpVtbl.*.NotifyParentWindowPositionChanged.?(controller));
            }
            return 0;
        },
        c.WM_SETFOCUS => {
            if (shell.controller) |controller| {
                check("MoveFocus", controller.lpVtbl.*.MoveFocus.?(controller, c.COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC));
            }
            return 0;
        },
        c.WM_DPICHANGED => {
            const suggested: *const c.RECT = @ptrFromInt(@as(usize, @intCast(lparam)));
            if (c.SetWindowPos(window, null, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0) {
                fatal("SetWindowPos failed after a DPI change, error {d}", .{c.GetLastError()});
            }
            return 0;
        },
        c.WM_COMMAND => {
            const command_id: usize = wparam & 0xFFFF;
            if (command_id < first_command_id or command_id - first_command_id >= shell.menu_actions.items.len) {
                return c.DefWindowProcW(window, message, wparam, lparam);
            }
            runAction(shell, shell.menu_actions.items[command_id - first_command_id].action);
            return 0;
        },
        WM_ZIGGY_MENU => {
            handleMenuRequest(shell, @ptrFromInt(@as(usize, @intCast(lparam))));
            return 0;
        },
        WM_ZIGGY_PICK => {
            handlePickRequest(shell, @ptrFromInt(@as(usize, @intCast(lparam))));
            return 0;
        },
        WM_ZIGGY_DELIVER => {
            drainQueue(shell);
            return 0;
        },
        c.WM_CLOSE => {
            shell.closing = true;
            destroyCore(shell);
            closeWebView(shell);
            if (c.DestroyWindow(window) == 0) {
                fatal("DestroyWindow failed, error {d}", .{c.GetLastError()});
            }
            return 0;
        },
        c.WM_DESTROY => {
            c.PostQuitMessage(0);
            return 0;
        },
        else => {
            return c.DefWindowProcW(window, message, wparam, lparam);
        },
    }
}

//
// Makes the web view fill the window's client area.
//
fn resizeWebView(shell: *Shell) void {
    const controller = shell.controller orelse {
        return;
    };
    var bounds: c.RECT = undefined;
    if (c.GetClientRect(shell.window, &bounds) == 0) {
        fatal("GetClientRect failed, error {d}", .{c.GetLastError()});
    }
    check("put_Bounds", controller.lpVtbl.*.put_Bounds.?(controller, bounds));
}

//
// Closes the web view and lets go of it.
//
fn closeWebView(shell: *Shell) void {
    if (shell.web_view) |web_view| {
        _ = web_view.lpVtbl.*.Release.?(web_view);
        shell.web_view = null;
    }
    if (shell.controller) |controller| {
        check("Close", controller.lpVtbl.*.Close.?(controller));
        _ = controller.lpVtbl.*.Release.?(controller);
        shell.controller = null;
    }
}

//
// Destroys the core once. After it nothing more is delivered to the page.
//
fn destroyCore(shell: *Shell) void {
    const core = shell.core orelse {
        return;
    };
    shell.destroyed.store(true, .release);
    shell.core = null;
    c.ziggy_destroy(core);
}

fn discardPending(shell: *Shell, allocator: std.mem.Allocator) void {
    for (shell.queue.items) |text| {
        allocator.free(text);
    }
    shell.queue.clearRetainingCapacity();
}

//
// The core's deliver callback. It runs on any thread: it queues the message and asks the UI thread to deliver it.
//
fn deliver(user_data: ?*anyopaque, message: [*c]const u8, message_len: usize) callconv(.c) void {
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    if (shell.destroyed.load(.acquire)) {
        return;
    }
    const text = std.heap.c_allocator.dupe(u8, message[0..message_len]) catch @panic("out of memory delivering a message");
    c.AcquireSRWLockExclusive(&shell.queue_lock);
    shell.queue.append(std.heap.c_allocator, text) catch @panic("out of memory delivering a message");
    c.ReleaseSRWLockExclusive(&shell.queue_lock);
    if (c.PostMessageW(shell.window, WM_ZIGGY_DELIVER, 0, 0) == 0) {
        fatal("could not wake the UI thread to deliver a message, error {d}", .{c.GetLastError()});
    }
}

//
// Runs on the UI thread: sends every queued message to the page, in the order they were queued.
//
fn drainQueue(shell: *Shell) void {
    const allocator = std.heap.c_allocator;
    c.AcquireSRWLockExclusive(&shell.queue_lock);
    var batch = shell.queue;
    shell.queue = .empty;
    c.ReleaseSRWLockExclusive(&shell.queue_lock);
    defer batch.deinit(allocator);
    for (batch.items) |text| {
        defer allocator.free(text);
        if (shell.destroyed.load(.acquire)) {
            continue;
        }
        const web_view = shell.web_view orelse {
            fatal("a message arrived from the core before the web view existed", .{});
        };
        const script = std.fmt.allocPrint(allocator, "window.__ziggyReceive({s});", .{text}) catch @panic("out of memory delivering a message");
        defer allocator.free(script);
        const wide_script = std.unicode.utf8ToUtf16LeAllocZ(allocator, script) catch {
            fatal("a message from the core is not valid UTF-8", .{});
        };
        defer allocator.free(wide_script);
        check("ExecuteScript", web_view.lpVtbl.*.ExecuteScript.?(web_view, wide_script.ptr, &shell.script_executed_handler.interface));
    }
}

//
// The native host callback that answers the operating system's version.
//
fn osVersion(user_data: ?*anyopaque, buffer: [*c]u8, capacity: usize) callconv(.c) isize {
    _ = user_data;
    var info = std.mem.zeroes(std.os.windows.RTL_OSVERSIONINFOW);
    info.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
    if (std.os.windows.ntdll.RtlGetVersion(&info) != .SUCCESS) {
        return -1;
    }
    const written = std.fmt.bufPrint(buffer[0..capacity], "\"Windows {d}.{d}.{d} {s}\"", .{
        info.dwMajorVersion,
        info.dwMinorVersion,
        info.dwBuildNumber,
        @tagName(builtin.cpu.arch),
    }) catch {
        return -1;
    };
    return @intCast(written.len);
}

//
// The native host callback that quits the application, asked for by the test control connection. It can be called from any
// thread, so it posts a close to the UI thread, which closes the window the same way the user closing it does.
//
fn quit(user_data: ?*anyopaque) callconv(.c) void {
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    if (c.PostMessageW(shell.window, c.WM_CLOSE, 0, 0) == 0) {
        fatal("could not post a close to the UI thread, error {d}", .{c.GetLastError()});
    }
}

//
// Opens an address in the system browser (or the mail program, for a mailto address).
//
fn openExternally(address: [*:0]const u16) void {
    const result = c.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), address, null, null, c.SW_SHOWNORMAL);
    if (@intFromPtr(result) <= 32) {
        fatal("could not open an external link, ShellExecute returned {d}", .{@intFromPtr(result)});
    }
}

//
// Converts an address WebView2 gave out to UTF-8 and frees the WebView2 string. The caller owns the result.
//
fn takeAddress(wide: [*c]c.WCHAR) []u8 {
    defer c.CoTaskMemFree(wide);
    const length = std.mem.len(@as([*:0]const u16, @ptrCast(wide)));
    return std.unicode.utf16LeToUtf8Alloc(std.heap.c_allocator, wide[0..length]) catch {
        fatal("the web view gave an address that cannot be converted to UTF-8", .{});
    };
}

//
// Asks the core what to do with an address. An address is blocked once the core is gone.
//
fn checkAddress(shell: *Shell, address: []const u8) i32 {
    const core = shell.core orelse {
        return c.ZIGGY_URL_BLOCK;
    };
    return c.ziggy_check_url(core, address.ptr, address.len);
}

//
// Starts the core, registers for the web view's events and adds the injected script. Runs once the web view exists.
//
fn onControllerCreated(shell: *Shell, controller: *c.ICoreWebView2Controller) void {
    _ = controller.lpVtbl.*.AddRef.?(controller);
    shell.controller = controller;
    var web_view: ?*c.ICoreWebView2 = null;
    check("get_CoreWebView2", controller.lpVtbl.*.get_CoreWebView2.?(controller, @ptrCast(&web_view)));
    const created_web_view = web_view orelse {
        fatal("the web view controller gave no web view", .{});
    };
    shell.web_view = created_web_view;
    resizeWebView(shell);

    var config = std.mem.zeroes(c.ziggy_config);
    config.user_data = shell;
    config.deliver = deliver;
    config.os_version = osVersion;
    config.quit = quit;
    config.pick_paths = pickPaths;
    config.menu_action = menuAction;
    var system_info: c.SYSTEM_INFO = undefined;
    c.GetSystemInfo(&system_info);
    config.worker_threads = system_info.dwNumberOfProcessors;
    config.max_concurrent_child_tasks = 10;
    config.app_url_prefix = shell.app_url_prefix.ptr;
    config.data_dir = shell.data_directory.ptr;
    if (shell.test_mode) {
        config.test_mode = true;
        if (shell.test_port_file) |port_file| {
            config.test_port_file = port_file.ptr;
        }
    }
    shell.core = c.ziggy_create(&config) orelse {
        fatal("the core could not be created", .{});
    };

    var settings: ?*c.ICoreWebView2Settings = null;
    check("get_Settings", created_web_view.lpVtbl.*.get_Settings.?(created_web_view, @ptrCast(&settings)));
    const web_view_settings = settings orelse {
        fatal("the web view gave no settings", .{});
    };
    // Developer tools are part of a normal desktop app, so they are on in a release build too.
    check("put_AreDevToolsEnabled", web_view_settings.lpVtbl.*.put_AreDevToolsEnabled.?(web_view_settings, 1));
    _ = web_view_settings.lpVtbl.*.Release.?(web_view_settings);
    buildMenu(shell, shell.core.?) catch |err| {
        fatal("could not build the menu: {s}", .{@errorName(err)});
    };

    var token: c.EventRegistrationToken = undefined;
    check("add_AcceleratorKeyPressed", controller.lpVtbl.*.add_AcceleratorKeyPressed.?(controller, &shell.accelerator_handler.interface, &token));
    check("add_WebMessageReceived", created_web_view.lpVtbl.*.add_WebMessageReceived.?(created_web_view, &shell.web_message_handler.interface, &token));
    check("add_NavigationStarting", created_web_view.lpVtbl.*.add_NavigationStarting.?(created_web_view, &shell.navigation_handler.interface, &token));
    check("add_NewWindowRequested", created_web_view.lpVtbl.*.add_NewWindowRequested.?(created_web_view, &shell.new_window_handler.interface, &token));
    check("AddScriptToExecuteOnDocumentCreated", created_web_view.lpVtbl.*.AddScriptToExecuteOnDocumentCreated.?(created_web_view, shell.inject_script.ptr, &shell.script_added_handler.interface));
}

//
// Reads which of Control, Shift, Alt and the Windows key are held, as accelerator modifier bits.
//
fn heldModifiers() u32 {
    var held: u32 = 0;
    if (c.GetKeyState(c.VK_CONTROL) < 0) {
        held |= accelerator_lib.modifier_control;
    }
    if (c.GetKeyState(c.VK_SHIFT) < 0) {
        held |= accelerator_lib.modifier_shift;
    }
    if (c.GetKeyState(c.VK_MENU) < 0) {
        held |= accelerator_lib.modifier_alt;
    }
    if (c.GetKeyState(c.VK_LWIN) < 0 or c.GetKeyState(c.VK_RWIN) < 0) {
        held |= accelerator_lib.modifier_windows;
    }
    return held;
}

//
// Adds the items of one menu or submenu to a Win32 menu, recording each item that does something in the shell's list of
// menu actions. The menu's label text is shown with the shortcut after a tab, as Windows menus do.
//
fn appendMenuItems(shell: *Shell, allocator: std.mem.Allocator, win32_menu: c.HMENU, items: []const menu_lib.MenuItem) !void {
    for (items) |item| {
        if (item.separator) {
            if (c.AppendMenuW(win32_menu, c.MF_SEPARATOR, 0, null) == 0) {
                return error.MenuBuildFailed;
            }
            continue;
        }
        const label = item.label orelse {
            return error.MenuItemHasNoLabel;
        };
        const escaped = try menu_lib.escapeLabel(allocator, label);
        defer allocator.free(escaped);
        if (item.items) |sub_items| {
            const submenu = c.CreatePopupMenu() orelse {
                return error.MenuBuildFailed;
            };
            try appendMenuItems(shell, allocator, submenu, sub_items);
            const wide_label = try std.unicode.utf8ToUtf16LeAllocZ(allocator, escaped);
            defer allocator.free(wide_label);
            if (c.AppendMenuW(win32_menu, c.MF_POPUP, @intFromPtr(submenu), wide_label.ptr) == 0) {
                return error.MenuBuildFailed;
            }
            continue;
        }
        const action = item.action orelse {
            return error.MenuItemHasNoAction;
        };
        var binding: ?accelerator_lib.Binding = null;
        var text = try allocator.dupe(u8, escaped);
        defer allocator.free(text);
        if (item.accelerator) |accelerator_text| {
            var parsed: c.ziggy_accelerator = undefined;
            if (!c.ziggy_parse_accelerator(accelerator_text.ptr, accelerator_text.len, &parsed)) {
                std.debug.print("ziggy shell: the menu item \"{s}\" has a shortcut that is not valid: {s}\n", .{ label, accelerator_text });
                return error.InvalidShortcut;
            }
            const key_name = std.mem.sliceTo(&parsed.key, 0);
            binding = accelerator_lib.bindingFor(parsed.modifiers, key_name) orelse {
                std.debug.print("ziggy shell: the menu item \"{s}\" has a shortcut with a key this shell does not know: {s}\n", .{ label, key_name });
                return error.UnknownShortcutKey;
            };
            var shortcut_buffer: [64]u8 = undefined;
            const shortcut = try accelerator_lib.formatShortcut(&shortcut_buffer, parsed.modifiers, key_name);
            allocator.free(text);
            text = try std.fmt.allocPrint(allocator, "{s}\t{s}", .{ escaped, shortcut });
        }
        const wide_text = try std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
        defer allocator.free(wide_text);
        const command_id = first_command_id + shell.menu_actions.items.len;
        try shell.menu_actions.append(allocator, .{
            .action = try allocator.dupe(u8, action),
            .binding = binding,
        });
        if (c.AppendMenuW(win32_menu, c.MF_STRING, command_id, wide_text.ptr) == 0) {
            return error.MenuBuildFailed;
        }
    }
}

//
// Builds the table of shortcuts the message loop uses when the window itself has the keyboard, with an entry for each key a
// shortcut matches. A shortcut with the Windows key is left out, because a table cannot hold one.
//
fn buildAcceleratorTable(shell: *Shell, allocator: std.mem.Allocator) !void {
    var entries: std.ArrayList(c.ACCEL) = .empty;
    defer entries.deinit(allocator);
    for (shell.menu_actions.items, 0..) |menu_action, index| {
        const binding = menu_action.binding orelse {
            continue;
        };
        if (binding.modifiers & accelerator_lib.modifier_windows != 0) {
            continue;
        }
        var flags: c.BYTE = c.FVIRTKEY;
        if (binding.modifiers & accelerator_lib.modifier_control != 0) {
            flags |= c.FCONTROL;
        }
        if (binding.modifiers & accelerator_lib.modifier_alt != 0) {
            flags |= c.FALT;
        }
        const keys = [_]c.WORD{ @intCast(binding.virtual_key), @intCast(binding.alternate_virtual_key) };
        for (keys) |key| {
            if (key == 0) {
                continue;
            }
            const command: c.WORD = @intCast(first_command_id + index);
            var shifted_flags = flags;
            if (binding.modifiers & accelerator_lib.modifier_shift != 0 or binding.shift_optional) {
                shifted_flags |= c.FSHIFT;
            }
            if (binding.shift_optional) {
                try entries.append(allocator, .{
                    .fVirt = flags,
                    .key = key,
                    .cmd = command,
                });
            }
            try entries.append(allocator, .{
                .fVirt = shifted_flags,
                .key = key,
                .cmd = command,
            });
        }
    }
    if (entries.items.len == 0) {
        return;
    }
    shell.accelerator_table = c.CreateAcceleratorTableW(entries.items.ptr, @intCast(entries.items.len)) orelse {
        return error.AcceleratorTableFailed;
    };
}

//
// Reads the menu from the core and, when it has any menus, puts them in a menu bar on the window and builds the shortcuts.
// A menu of no menus shows no menu bar.
//
fn buildMenu(shell: *Shell, core: *anyopaque) !void {
    const allocator = std.heap.c_allocator;
    var length: usize = 0;
    const json_pointer = c.ziggy_menu_json(core, &length) orelse {
        return error.MenuMissing;
    };
    const parsed = try menu_lib.parseMenu(allocator, json_pointer[0..length]);
    defer parsed.deinit();
    if (parsed.value.len == 0) {
        return;
    }
    const menu_bar = c.CreateMenu() orelse {
        return error.MenuBuildFailed;
    };
    for (parsed.value) |menu| {
        const popup = c.CreatePopupMenu() orelse {
            return error.MenuBuildFailed;
        };
        try appendMenuItems(shell, allocator, popup, menu.items);
        const escaped = try menu_lib.escapeLabel(allocator, menu.label);
        defer allocator.free(escaped);
        const wide_label = try std.unicode.utf8ToUtf16LeAllocZ(allocator, escaped);
        defer allocator.free(wide_label);
        if (c.AppendMenuW(menu_bar, c.MF_POPUP, @intFromPtr(popup), wide_label.ptr) == 0) {
            return error.MenuBuildFailed;
        }
    }
    shell.menu_bar = menu_bar;
    if (c.SetMenu(shell.window, menu_bar) == 0) {
        return error.MenuBuildFailed;
    }
    try buildAcceleratorTable(shell, allocator);
    resizeWebView(shell);
}

//
// Runs a menu action. The actions the shell knows are done here, and any other is sent to the core as a menu-action
// message, which the core hands to the page.
//
fn runAction(shell: *Shell, action: []const u8) void {
    const known = actions_lib.fromName(action) orelse {
        sendMenuAction(shell, action);
        return;
    };
    const web_view = shell.web_view orelse {
        fatal("the menu action {s} ran before the web view existed", .{action});
    };
    const controller = shell.controller orelse {
        fatal("the menu action {s} ran before the web view existed", .{action});
    };
    switch (known) {
        .quit => {
            if (c.PostMessageW(shell.window, c.WM_CLOSE, 0, 0) == 0) {
                fatal("could not post a close to the window, error {d}", .{c.GetLastError()});
            }
        },
        .reload => {
            check("Reload", web_view.lpVtbl.*.Reload.?(web_view));
        },
        .toggle_devtools => {
            check("OpenDevToolsWindow", web_view.lpVtbl.*.OpenDevToolsWindow.?(web_view));
        },
        .toggle_fullscreen => {
            toggleFullscreen(shell);
        },
        .zoom_in => {
            changeZoom(controller, 1);
        },
        .zoom_out => {
            changeZoom(controller, -1);
        },
        .zoom_reset => {
            changeZoom(controller, 0);
        },
        .copy => {
            copySelection(web_view, &shell.copy_handler.interface);
        },
        .cut => {
            copySelection(web_view, &shell.cut_handler.interface);
        },
        .paste => {
            pasteClipboard(shell, web_view);
        },
        .undo, .redo, .select_all => {
            runEditCommand(shell, web_view, actions_lib.editCommand(known).?);
        },
    }
}

//
// Sends an action that belongs to the app to the core, as the message {"channel":"menu-action","data":{"action":...}}.
//
fn sendMenuAction(shell: *Shell, action: []const u8) void {
    const core = shell.core orelse {
        return;
    };
    const message = actions_lib.menuActionMessage(std.heap.c_allocator, action) catch {
        fatal("out of memory sending the menu action {s}", .{action});
    };
    defer std.heap.c_allocator.free(message);
    c.ziggy_post_message(core, message.ptr, message.len);
}

//
// Steps the page zoom up or down by a tenth, or back to 100 percent for a direction of zero.
//
fn changeZoom(controller: *c.ICoreWebView2Controller, direction: i32) void {
    var current: f64 = 1.0;
    check("get_ZoomFactor", controller.lpVtbl.*.get_ZoomFactor.?(controller, &current));
    check("put_ZoomFactor", controller.lpVtbl.*.put_ZoomFactor.?(controller, actions_lib.nextZoom(current, direction)));
}

//
// Runs a script in the page, with the handler that receives its result.
//
fn runScript(web_view: *c.ICoreWebView2, script: []const u8, handler: *c.ICoreWebView2ExecuteScriptCompletedHandler) void {
    const allocator = std.heap.c_allocator;
    const wide_script = std.unicode.utf8ToUtf16LeAllocZ(allocator, script) catch {
        fatal("a script to run in the page is not valid text", .{});
    };
    defer allocator.free(wide_script);
    check("ExecuteScript", web_view.lpVtbl.*.ExecuteScript.?(web_view, wide_script.ptr, handler));
}

//
// Copies the selected text to the clipboard. document.execCommand('copy') and ('cut') are refused to a script, which has no
// user gesture, so the shell asks the page for the selected text and puts it on the clipboard itself.
//
fn copySelection(web_view: *c.ICoreWebView2, handler: *c.ICoreWebView2ExecuteScriptCompletedHandler) void {
    runScript(web_view, actions_lib.selection_script, handler);
}

//
// Types the clipboard's text into the focused field. Text is the only kind of clipboard content it handles, and a clipboard
// with none pastes nothing.
//
fn pasteClipboard(shell: *Shell, web_view: *c.ICoreWebView2) void {
    const allocator = std.heap.c_allocator;
    if (c.OpenClipboard(shell.window) == 0) {
        std.debug.print("ziggy shell: could not open the clipboard to paste, error {d}\n", .{c.GetLastError()});
        return;
    }
    defer _ = c.CloseClipboard();
    const handle = c.GetClipboardData(c.CF_UNICODETEXT) orelse {
        return;
    };
    const locked = c.GlobalLock(handle) orelse {
        fatal("GlobalLock failed on the clipboard text, error {d}", .{c.GetLastError()});
    };
    defer _ = c.GlobalUnlock(handle);
    const text = std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(@as([*:0]const u16, @ptrCast(@alignCast(locked))))) catch {
        fatal("the clipboard text cannot be converted to UTF-8", .{});
    };
    defer allocator.free(text);
    const script = actions_lib.pasteScript(allocator, text) catch {
        fatal("out of memory pasting", .{});
    };
    defer allocator.free(script);
    runScript(web_view, script, &shell.script_executed_handler.interface);
}

//
// Puts text on the clipboard, replacing what it held.
//
fn setClipboardText(shell: *Shell, text: []const u8) void {
    const allocator = std.heap.c_allocator;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, text) catch {
        fatal("the text to copy is not valid UTF-8", .{});
    };
    defer allocator.free(wide);
    const bytes = (wide.len + 1) * @sizeOf(u16);
    const memory = c.GlobalAlloc(c.GMEM_MOVEABLE, bytes) orelse {
        fatal("GlobalAlloc failed copying to the clipboard, error {d}", .{c.GetLastError()});
    };
    const locked = c.GlobalLock(memory) orelse {
        fatal("GlobalLock failed copying to the clipboard, error {d}", .{c.GetLastError()});
    };
    @memcpy(@as([*]u8, @ptrCast(locked))[0..bytes], std.mem.sliceAsBytes(wide.ptr[0 .. wide.len + 1]));
    _ = c.GlobalUnlock(memory);
    if (c.OpenClipboard(shell.window) == 0) {
        _ = c.GlobalFree(memory);
        std.debug.print("ziggy shell: could not open the clipboard to copy, error {d}\n", .{c.GetLastError()});
        return;
    }
    defer _ = c.CloseClipboard();
    if (c.EmptyClipboard() == 0) {
        _ = c.GlobalFree(memory);
        fatal("EmptyClipboard failed, error {d}", .{c.GetLastError()});
    }
    if (c.SetClipboardData(c.CF_UNICODETEXT, memory) == null) {
        _ = c.GlobalFree(memory);
        fatal("SetClipboardData failed, error {d}", .{c.GetLastError()});
    }
}

//
// The page has returned the selected text: puts it on the clipboard. Nothing selected leaves the clipboard as it was.
//
fn takeSelection(shell: *Shell, error_code: c.HRESULT, result: [*c]const c.WCHAR) bool {
    check("reading the selected text", error_code);
    const allocator = std.heap.c_allocator;
    const json = std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(@as([*:0]const u16, @ptrCast(result)))) catch {
        fatal("the selected text cannot be converted to UTF-8", .{});
    };
    defer allocator.free(json);
    const text = actions_lib.selectionText(allocator, json) catch |err| {
        fatal("the page gave a selection that is not a string: {s}", .{@errorName(err)});
    };
    defer allocator.free(text);
    if (text.len == 0) {
        return false;
    }
    setClipboardText(shell, text);
    return true;
}

fn copyInvoke(this: [*c]c.ICoreWebView2ExecuteScriptCompletedHandler, error_code: c.HRESULT, result: [*c]const c.WCHAR) callconv(.c) c.HRESULT {
    _ = takeSelection(ScriptExecutedHandler.fromInterface(this).shell, error_code, result);
    return c.S_OK;
}

//
// The page has returned the selected text for a cut: puts it on the clipboard and deletes it from the page.
//
fn cutInvoke(this: [*c]c.ICoreWebView2ExecuteScriptCompletedHandler, error_code: c.HRESULT, result: [*c]const c.WCHAR) callconv(.c) c.HRESULT {
    const shell = ScriptExecutedHandler.fromInterface(this).shell;
    if (takeSelection(shell, error_code, result)) {
        runEditCommand(shell, shell.web_view.?, "delete");
    }
    return c.S_OK;
}

//
// The native host callback that does a menu action as if its item had been chosen, used by the test control connection. It
// runs on that connection's thread, so it hands a copy of the action to the UI thread and returns.
//
fn menuAction(user_data: ?*anyopaque, action: [*c]const u8) callconv(.c) void {
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    const copy = std.heap.c_allocator.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(action)))) catch @panic("out of memory choosing a menu action");
    if (c.PostMessageW(shell.window, WM_ZIGGY_MENU, 0, @intCast(@intFromPtr(copy.ptr))) == 0) {
        std.heap.c_allocator.free(copy);
        fatal("could not ask the UI thread to do a menu action, error {d}", .{c.GetLastError()});
    }
}

//
// Runs on the UI thread: does the menu action a menu action request carries, with the function a menu click uses, and frees it.
//
fn handleMenuRequest(shell: *Shell, action: [*:0]u8) void {
    const text = std.mem.span(action);
    defer std.heap.c_allocator.free(text);
    if (shell.destroyed.load(.acquire)) {
        return;
    }
    runAction(shell, text);
}

//
// Runs an editing command in the page with document.execCommand, because WebView2 has no editing commands of its own.
//
fn runEditCommand(shell: *Shell, web_view: *c.ICoreWebView2, command: []const u8) void {
    var script_buffer: [96]u8 = undefined;
    const script = std.fmt.bufPrint(&script_buffer, "document.execCommand('{s}');", .{command}) catch {
        fatal("the editing command {s} is too long", .{command});
    };
    var wide_buffer: [96:0]u16 = undefined;
    const wide_length = std.unicode.utf8ToUtf16Le(&wide_buffer, script) catch {
        fatal("the editing command {s} is not valid text", .{command});
    };
    wide_buffer[wide_length] = 0;
    check("ExecuteScript", web_view.lpVtbl.*.ExecuteScript.?(web_view, &wide_buffer, &shell.script_executed_handler.interface));
}

//
// Switches the window between full screen and what it was: without the title bar, borders and menu bar, covering the
// monitor it is on, and then restoring its style, menu and its previous place and state (including maximized).
//
fn toggleFullscreen(shell: *Shell) void {
    if (!shell.fullscreen) {
        shell.saved_placement.length = @sizeOf(c.WINDOWPLACEMENT);
        if (c.GetWindowPlacement(shell.window, &shell.saved_placement) == 0) {
            fatal("GetWindowPlacement failed, error {d}", .{c.GetLastError()});
        }
        var monitor_info = std.mem.zeroes(c.MONITORINFO);
        monitor_info.cbSize = @sizeOf(c.MONITORINFO);
        if (c.GetMonitorInfoW(c.MonitorFromWindow(shell.window, c.MONITOR_DEFAULTTONEAREST), &monitor_info) == 0) {
            fatal("GetMonitorInfo failed, error {d}", .{c.GetLastError()});
        }
        _ = c.SetWindowLongPtrW(shell.window, c.GWL_STYLE, @as(c.LONG_PTR, @intCast(window_style & ~@as(c.DWORD, c.WS_OVERLAPPEDWINDOW))) | c.WS_VISIBLE);
        _ = c.SetMenu(shell.window, null);
        const bounds = monitor_info.rcMonitor;
        if (c.SetWindowPos(shell.window, null, bounds.left, bounds.top, bounds.right - bounds.left, bounds.bottom - bounds.top, c.SWP_NOOWNERZORDER | c.SWP_FRAMECHANGED) == 0) {
            fatal("SetWindowPos failed going full screen, error {d}", .{c.GetLastError()});
        }
        shell.fullscreen = true;
        return;
    }
    _ = c.SetWindowLongPtrW(shell.window, c.GWL_STYLE, @as(c.LONG_PTR, @intCast(window_style)) | c.WS_VISIBLE);
    if (shell.menu_bar != null) {
        _ = c.SetMenu(shell.window, shell.menu_bar);
    }
    if (c.SetWindowPlacement(shell.window, &shell.saved_placement) == 0) {
        fatal("SetWindowPlacement failed, error {d}", .{c.GetLastError()});
    }
    if (c.SetWindowPos(shell.window, null, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOOWNERZORDER | c.SWP_FRAMECHANGED) == 0) {
        fatal("SetWindowPos failed leaving full screen, error {d}", .{c.GetLastError()});
    }
    shell.fullscreen = false;
}

//
// A key was pressed with the keyboard inside the web view, before the page sees it. When it is a menu shortcut the shell
// runs the action and marks the key handled. The editing shortcuts are left to the web view, which does them natively.
//
fn acceleratorInvoke(this: [*c]c.ICoreWebView2AcceleratorKeyPressedEventHandler, sender: [*c]c.ICoreWebView2Controller, args: [*c]c.ICoreWebView2AcceleratorKeyPressedEventArgs) callconv(.c) c.HRESULT {
    _ = sender;
    const shell = AcceleratorHandler.fromInterface(this).shell;
    var kind: c.COREWEBVIEW2_KEY_EVENT_KIND = undefined;
    check("get_KeyEventKind", args.*.lpVtbl.*.get_KeyEventKind.?(args, &kind));
    if (kind != c.COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN and kind != c.COREWEBVIEW2_KEY_EVENT_KIND_SYSTEM_KEY_DOWN) {
        return c.S_OK;
    }
    var virtual_key: c.UINT = 0;
    check("get_VirtualKey", args.*.lpVtbl.*.get_VirtualKey.?(args, &virtual_key));
    const held = heldModifiers();
    for (shell.menu_actions.items) |menu_action| {
        const binding = menu_action.binding orelse {
            continue;
        };
        if (!accelerator_lib.matches(binding, virtual_key, held)) {
            continue;
        }
        const known = actions_lib.fromName(menu_action.action);
        if (known != null and actions_lib.editCommand(known.?) != null) {
            return c.S_OK;
        }
        check("put_Handled", args.*.lpVtbl.*.put_Handled.?(args, 1));
        var status = std.mem.zeroes(c.COREWEBVIEW2_PHYSICAL_KEY_STATUS);
        check("get_PhysicalKeyStatus", args.*.lpVtbl.*.get_PhysicalKeyStatus.?(args, &status));
        if (status.WasKeyDown == 0) {
            runAction(shell, menu_action.action);
        }
        return c.S_OK;
    }
    return c.S_OK;
}

//
// A request for a file or folder dialog, passed from the worker thread that wants the answer to the UI thread that shows the
// dialog. It lives on the heap and is shared by those two threads, each holding a reference, because the worker gives up
// waiting when the shell is closing and the UI thread may still be inside the dialog. The UI thread never touches the
// worker's buffer: it leaves the answer here and the worker copies it out.
//
const PickRequest = struct {
    // Which dialog to show.
    kind: pickers_lib.PickKind,
    // The dialog's title as UTF-16. Owned.
    title: [:0]u16,
    // The suggested file name as UTF-16, or null for none. Owned.
    initial_name: ?[:0]u16,
    // Signalled by the UI thread when it has finished with the request. Owned.
    done: c.HANDLE,
    // How many of the two threads still hold the request.
    references: std.atomic.Value(u32),
    // The JSON array of chosen paths, or null when the dialog could not be shown. Set before done is signalled. Owned.
    answer: ?[]u8,
};

//
// Lets go of one reference to a request, and frees it when the other thread has let go too.
//
fn releasePickRequest(request: *PickRequest) void {
    if (request.references.fetchSub(1, .acq_rel) != 1) {
        return;
    }
    const allocator = std.heap.c_allocator;
    allocator.free(request.title);
    if (request.initial_name) |name| {
        allocator.free(name);
    }
    if (request.answer) |answer| {
        allocator.free(answer);
    }
    _ = c.CloseHandle(request.done);
    allocator.destroy(request);
}

//
// The native host callback that shows a file or folder dialog and writes the chosen paths as a JSON array into the buffer. It
// runs on a worker thread, so it asks the UI thread to show the dialog and waits there for the answer. Returns the number of
// bytes written, or -1 and a message on standard error when the dialog could not be shown or the answer does not fit.
//
fn pickPaths(user_data: ?*anyopaque, kind: i32, title: [*c]const u8, initial_name: [*c]const u8, buffer: [*c]u8, capacity: usize) callconv(.c) isize {
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    const allocator = std.heap.c_allocator;
    const pick_kind = pickers_lib.kindFromInt(kind) orelse {
        std.debug.print("ziggy shell: the core asked for a dialog of kind {d}, which is not one\n", .{kind});
        return -1;
    };
    const title_text: []const u8 = if (title == null) pickers_lib.defaultTitle(pick_kind) else std.mem.span(@as([*:0]const u8, @ptrCast(title)));
    const wide_title = std.unicode.utf8ToUtf16LeAllocZ(allocator, title_text) catch {
        std.debug.print("ziggy shell: the dialog title cannot be converted to UTF-16\n", .{});
        return -1;
    };
    var wide_name: ?[:0]u16 = null;
    if (initial_name != null) {
        wide_name = std.unicode.utf8ToUtf16LeAllocZ(allocator, std.mem.span(@as([*:0]const u8, @ptrCast(initial_name)))) catch {
            allocator.free(wide_title);
            std.debug.print("ziggy shell: the suggested file name cannot be converted to UTF-16\n", .{});
            return -1;
        };
    }
    const done = c.CreateEventW(null, 1, 0, null) orelse {
        allocator.free(wide_title);
        if (wide_name) |name| {
            allocator.free(name);
        }
        std.debug.print("ziggy shell: could not create an event to wait for the dialog, error {d}\n", .{c.GetLastError()});
        return -1;
    };
    const request = allocator.create(PickRequest) catch @panic("out of memory showing a dialog");
    request.* = .{
        .kind = pick_kind,
        .title = wide_title,
        .initial_name = wide_name,
        .done = done,
        .references = .init(2),
        .answer = null,
    };
    defer releasePickRequest(request);
    if (c.PostMessageW(shell.window, WM_ZIGGY_PICK, 0, @intCast(@intFromPtr(request))) == 0) {
        std.debug.print("ziggy shell: could not ask the UI thread to show a dialog, error {d}\n", .{c.GetLastError()});
        releasePickRequest(request);
        return -1;
    }
    // The window can close while the dialog is open. Closing waits for this thread, so it must not wait for the dialog.
    while (true) {
        const waited = c.WaitForSingleObject(request.done, 100);
        if (waited == c.WAIT_OBJECT_0) {
            break;
        }
        if (waited != c.WAIT_TIMEOUT) {
            std.debug.print("ziggy shell: waiting for the dialog failed, error {d}\n", .{c.GetLastError()});
            return -1;
        }
        if (shell.destroyed.load(.acquire)) {
            return -1;
        }
    }
    const answer = request.answer orelse {
        return -1;
    };
    if (answer.len > capacity) {
        std.debug.print("ziggy shell: the chosen paths do not fit in the {d} byte buffer\n", .{capacity});
        return -1;
    }
    @memcpy(buffer[0..answer.len], answer);
    return @intCast(answer.len);
}

//
// Runs on the UI thread: shows the dialog a worker asked for, which runs its own message loop, so the window and the web view
// keep working while it is open, and leaves the answer in the request.
//
fn handlePickRequest(shell: *Shell, request: *PickRequest) void {
    defer releasePickRequest(request);
    defer _ = c.SetEvent(request.done);
    if (shell.destroyed.load(.acquire)) {
        return;
    }
    request.answer = showPicker(shell, std.heap.c_allocator, request) catch |err| {
        std.debug.print("ziggy shell: the dialog failed: {s}\n", .{@errorName(err)});
        return;
    };
}

//
// The HRESULT a dialog's Show returns when the user cancels it.
//
const hresult_cancelled: c.HRESULT = @bitCast(@as(u32, 0x800704C7));

//
// Shows a Common Item Dialog and returns the JSON array of what the user chose, "[]" when the user cancelled. The caller owns
// the result.
//
fn showPicker(shell: *Shell, allocator: std.mem.Allocator, request: *PickRequest) ![]u8 {
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |path| {
            allocator.free(path);
        }
        paths.deinit(allocator);
    }
    if (request.kind == .save_file) {
        var save_dialog: ?*c.IFileSaveDialog = null;
        check("CoCreateInstance(FileSaveDialog)", c.CoCreateInstance(&c.CLSID_FileSaveDialog, null, c.CLSCTX_INPROC_SERVER, &c.IID_IFileSaveDialog, @ptrCast(&save_dialog)));
        const dialog = save_dialog orelse {
            return error.DialogMissing;
        };
        defer _ = dialog.lpVtbl.*.Release.?(dialog);
        var options: c.FILEOPENDIALOGOPTIONS = 0;
        check("GetOptions", dialog.lpVtbl.*.GetOptions.?(dialog, &options));
        check("SetOptions", dialog.lpVtbl.*.SetOptions.?(dialog, pickers_lib.dialogOptions(request.kind, options)));
        check("SetTitle", dialog.lpVtbl.*.SetTitle.?(dialog, request.title.ptr));
        if (request.initial_name) |name| {
            check("SetFileName", dialog.lpVtbl.*.SetFileName.?(dialog, name.ptr));
        }
        const shown = dialog.lpVtbl.*.Show.?(dialog, shell.window);
        if (shown == hresult_cancelled) {
            return pickers_lib.pathsJson(allocator, &.{});
        }
        check("Show", shown);
        var item: ?*c.IShellItem = null;
        check("GetResult", dialog.lpVtbl.*.GetResult.?(dialog, @ptrCast(&item)));
        try paths.append(allocator, try itemPath(allocator, item orelse return error.DialogGaveNoItem));
        return pickers_lib.pathsJson(allocator, paths.items);
    }
    var open_dialog: ?*c.IFileOpenDialog = null;
    check("CoCreateInstance(FileOpenDialog)", c.CoCreateInstance(&c.CLSID_FileOpenDialog, null, c.CLSCTX_INPROC_SERVER, &c.IID_IFileOpenDialog, @ptrCast(&open_dialog)));
    const dialog = open_dialog orelse {
        return error.DialogMissing;
    };
    defer _ = dialog.lpVtbl.*.Release.?(dialog);
    var options: c.FILEOPENDIALOGOPTIONS = 0;
    check("GetOptions", dialog.lpVtbl.*.GetOptions.?(dialog, &options));
    check("SetOptions", dialog.lpVtbl.*.SetOptions.?(dialog, pickers_lib.dialogOptions(request.kind, options)));
    check("SetTitle", dialog.lpVtbl.*.SetTitle.?(dialog, request.title.ptr));
    const shown = dialog.lpVtbl.*.Show.?(dialog, shell.window);
    if (shown == hresult_cancelled) {
        return pickers_lib.pathsJson(allocator, &.{});
    }
    check("Show", shown);
    var results: ?*c.IShellItemArray = null;
    check("GetResults", dialog.lpVtbl.*.GetResults.?(dialog, @ptrCast(&results)));
    const chosen = results orelse {
        return error.DialogGaveNoItem;
    };
    defer _ = chosen.lpVtbl.*.Release.?(chosen);
    var count: c.DWORD = 0;
    check("GetCount", chosen.lpVtbl.*.GetCount.?(chosen, &count));
    var index: c.DWORD = 0;
    while (index < count) : (index += 1) {
        var item: ?*c.IShellItem = null;
        check("GetItemAt", chosen.lpVtbl.*.GetItemAt.?(chosen, index, @ptrCast(&item)));
        try paths.append(allocator, try itemPath(allocator, item orelse return error.DialogGaveNoItem));
    }
    return pickers_lib.pathsJson(allocator, paths.items);
}

//
// Returns the file system path of a chosen item as UTF-8 and lets go of the item. The caller owns the result.
//
fn itemPath(allocator: std.mem.Allocator, item: *c.IShellItem) ![]u8 {
    defer _ = item.lpVtbl.*.Release.?(item);
    var wide: [*c]c.WCHAR = null;
    check("GetDisplayName", item.lpVtbl.*.GetDisplayName.?(item, c.SIGDN_FILESYSPATH, &wide));
    defer c.CoTaskMemFree(wide);
    return std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(@as([*:0]const u16, @ptrCast(wide))));
}

fn environmentInvoke(this: [*c]c.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, error_code: c.HRESULT, environment: [*c]c.ICoreWebView2Environment) callconv(.c) c.HRESULT {
    const shell = EnvironmentHandler.fromInterface(this).shell;
    if (shell.closing) {
        return c.S_OK;
    }
    check("creating the WebView2 environment (is the WebView2 runtime installed?)", error_code);
    if (environment == null) {
        fatal("WebView2 gave no environment", .{});
    }
    check("CreateCoreWebView2Controller", environment.*.lpVtbl.*.CreateCoreWebView2Controller.?(environment, shell.window, &shell.controller_handler.interface));
    return c.S_OK;
}

fn controllerInvoke(this: [*c]c.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, error_code: c.HRESULT, controller: [*c]c.ICoreWebView2Controller) callconv(.c) c.HRESULT {
    const shell = ControllerHandler.fromInterface(this).shell;
    if (shell.closing) {
        return c.S_OK;
    }
    check("creating the WebView2 controller", error_code);
    if (controller == null) {
        fatal("WebView2 gave no controller", .{});
    }
    onControllerCreated(shell, controller);
    return c.S_OK;
}

//
// A message from the page: hands it to the core.
//
fn webMessageInvoke(this: [*c]c.ICoreWebView2WebMessageReceivedEventHandler, sender: [*c]c.ICoreWebView2, args: [*c]c.ICoreWebView2WebMessageReceivedEventArgs) callconv(.c) c.HRESULT {
    _ = sender;
    const shell = WebMessageHandler.fromInterface(this).shell;
    const core = shell.core orelse {
        return c.S_OK;
    };
    var wide: [*c]c.WCHAR = null;
    const status = args.*.lpVtbl.*.TryGetWebMessageAsString.?(args, &wide);
    if (status < 0) {
        fatal("the page posted a message that is not a string (HRESULT 0x{X:0>8})", .{@as(u32, @bitCast(status))});
    }
    const text = takeAddress(wide);
    defer std.heap.c_allocator.free(text);
    c.ziggy_post_message(core, text.ptr, text.len);
    return c.S_OK;
}

//
// Decides every navigation with the core's origin check: the app's own page loads, external links open in the system
// browser, and everything else is blocked.
//
fn navigationInvoke(this: [*c]c.ICoreWebView2NavigationStartingEventHandler, sender: [*c]c.ICoreWebView2, args: [*c]c.ICoreWebView2NavigationStartingEventArgs) callconv(.c) c.HRESULT {
    _ = sender;
    const shell = NavigationHandler.fromInterface(this).shell;
    var wide: [*c]c.WCHAR = null;
    check("get_Uri", args.*.lpVtbl.*.get_Uri.?(args, &wide));
    const address = takeAddress(wide);
    defer std.heap.c_allocator.free(address);
    const verdict = checkAddress(shell, address);
    if (verdict == c.ZIGGY_URL_ALLOW) {
        return c.S_OK;
    }
    check("put_Cancel", args.*.lpVtbl.*.put_Cancel.?(args, 1));
    if (verdict == c.ZIGGY_URL_OPEN_EXTERNALLY) {
        openAddress(address);
    }
    return c.S_OK;
}

//
// Blocks every request to open a new window, and opens external links in the system browser.
//
fn newWindowInvoke(this: [*c]c.ICoreWebView2NewWindowRequestedEventHandler, sender: [*c]c.ICoreWebView2, args: [*c]c.ICoreWebView2NewWindowRequestedEventArgs) callconv(.c) c.HRESULT {
    _ = sender;
    const shell = NewWindowHandler.fromInterface(this).shell;
    var wide: [*c]c.WCHAR = null;
    check("get_Uri", args.*.lpVtbl.*.get_Uri.?(args, &wide));
    const address = takeAddress(wide);
    defer std.heap.c_allocator.free(address);
    check("put_Handled", args.*.lpVtbl.*.put_Handled.?(args, 1));
    if (checkAddress(shell, address) == c.ZIGGY_URL_OPEN_EXTERNALLY) {
        openAddress(address);
    }
    return c.S_OK;
}

fn openAddress(address: []const u8) void {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, address) catch {
        fatal("an external link cannot be converted to UTF-16", .{});
    };
    defer std.heap.c_allocator.free(wide);
    openExternally(wide.ptr);
}

//
// The injected script is in place, so the page can load.
//
fn scriptAddedInvoke(this: [*c]c.ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler, error_code: c.HRESULT, id: [*c]const c.WCHAR) callconv(.c) c.HRESULT {
    _ = id;
    const shell = ScriptAddedHandler.fromInterface(this).shell;
    if (shell.closing) {
        return c.S_OK;
    }
    check("adding the injected script", error_code);
    const web_view = shell.web_view orelse {
        fatal("the injected script was added without a web view", .{});
    };
    check("Navigate", web_view.lpVtbl.*.Navigate.?(web_view, shell.page_url.ptr));
    return c.S_OK;
}

fn scriptExecutedInvoke(this: [*c]c.ICoreWebView2ExecuteScriptCompletedHandler, error_code: c.HRESULT, result: [*c]const c.WCHAR) callconv(.c) c.HRESULT {
    _ = this;
    _ = result;
    check("delivering a message to the page", error_code);
    return c.S_OK;
}

//
// The table of functions of the environment handler.
//
const environment_vtable = c.struct_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl{
    .QueryInterface = EnvironmentHandler.queryInterface,
    .AddRef = EnvironmentHandler.addRef,
    .Release = EnvironmentHandler.release,
    .Invoke = environmentInvoke,
};

//
// The table of functions of the controller handler.
//
const controller_vtable = c.struct_ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl{
    .QueryInterface = ControllerHandler.queryInterface,
    .AddRef = ControllerHandler.addRef,
    .Release = ControllerHandler.release,
    .Invoke = controllerInvoke,
};

//
// The table of functions of the web_message handler.
//
const web_message_vtable = c.struct_ICoreWebView2WebMessageReceivedEventHandlerVtbl{
    .QueryInterface = WebMessageHandler.queryInterface,
    .AddRef = WebMessageHandler.addRef,
    .Release = WebMessageHandler.release,
    .Invoke = webMessageInvoke,
};

//
// The table of functions of the navigation handler.
//
const navigation_vtable = c.struct_ICoreWebView2NavigationStartingEventHandlerVtbl{
    .QueryInterface = NavigationHandler.queryInterface,
    .AddRef = NavigationHandler.addRef,
    .Release = NavigationHandler.release,
    .Invoke = navigationInvoke,
};

//
// The table of functions of the new_window handler.
//
const new_window_vtable = c.struct_ICoreWebView2NewWindowRequestedEventHandlerVtbl{
    .QueryInterface = NewWindowHandler.queryInterface,
    .AddRef = NewWindowHandler.addRef,
    .Release = NewWindowHandler.release,
    .Invoke = newWindowInvoke,
};

//
// The table of functions of the script_added handler.
//
const script_added_vtable = c.struct_ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandlerVtbl{
    .QueryInterface = ScriptAddedHandler.queryInterface,
    .AddRef = ScriptAddedHandler.addRef,
    .Release = ScriptAddedHandler.release,
    .Invoke = scriptAddedInvoke,
};

//
// The table of functions of the script_executed handler.
//
const script_executed_vtable = c.struct_ICoreWebView2ExecuteScriptCompletedHandlerVtbl{
    .QueryInterface = ScriptExecutedHandler.queryInterface,
    .AddRef = ScriptExecutedHandler.addRef,
    .Release = ScriptExecutedHandler.release,
    .Invoke = scriptExecutedInvoke,
};

//
// The table of functions of the accelerator handler.
//
const accelerator_vtable = c.struct_ICoreWebView2AcceleratorKeyPressedEventHandlerVtbl{
    .QueryInterface = AcceleratorHandler.queryInterface,
    .AddRef = AcceleratorHandler.addRef,
    .Release = AcceleratorHandler.release,
    .Invoke = acceleratorInvoke,
};

//
// The table of functions of the copy handler.
//
const copy_vtable = c.struct_ICoreWebView2ExecuteScriptCompletedHandlerVtbl{
    .QueryInterface = ScriptExecutedHandler.queryInterface,
    .AddRef = ScriptExecutedHandler.addRef,
    .Release = ScriptExecutedHandler.release,
    .Invoke = copyInvoke,
};

//
// The table of functions of the cut handler.
//
const cut_vtable = c.struct_ICoreWebView2ExecuteScriptCompletedHandlerVtbl{
    .QueryInterface = ScriptExecutedHandler.queryInterface,
    .AddRef = ScriptExecutedHandler.addRef,
    .Release = ScriptExecutedHandler.release,
    .Invoke = cutInvoke,
};
