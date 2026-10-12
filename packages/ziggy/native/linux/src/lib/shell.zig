//
// Ziggy's Linux shell. It creates the window, hosts WebKitGTK, injects window.ziggy, loads the app's bundled page,
// calls the core through the C interface and moves messages between the page and the core.
//
// Messages from the core arrive on any thread, so they are queued and delivered to the web view from the GTK main thread.
//

const std = @import("std");
const c = @import("gtk.zig");
const z = @import("c");
const menu_keys = @import("menu-keys.zig");
const geometry_lib = @import("geometry.zig");
const ui_files = @import("ui-files");

// The URL scheme the bundled page is served under. WebKitGTK asks the shell for each file instead of reading a directory.
const app_scheme = "ziggy-app";

// The URL prefix of the bundled page, with a trailing slash. It is what the core allows the web view to navigate to.
const app_url_prefix = app_scheme ++ "://app/";

//
// What a host request handler can ask of the shell.
//
pub const Host = struct {
    // The shell the request came to.
    shell: *Shell,

    //
    // Holds the computer from suspending, or lets it go again. Calls nest: the computer may suspend again once every hold has been
    // let go. Can be called from any thread.
    //
    pub fn holdAwake(self: Host, awake: bool) void {
        _ = c.g_idle_add(if (awake) holdAwakeOnMainThread else releaseAwakeOnMainThread, self.shell);
    }
};

//
// Answers one host request. Gives the JSON text of the answer, null when the app does not know the method, or an error, whose name is
// the reason the request failed. Called from a worker thread.
//
pub const HostRequestFn = *const fn (host: Host, method: []const u8, request_json: []const u8) anyerror!?[]const u8;

//
// What an app tells the shell about itself.
//
pub const AppConfig = struct {
    // Answers the requests only the platform can do, by method name, or null when the app has none.
    host_request: ?HostRequestFn,
    // The application id, which also names the app's private data directory.
    app_id: [:0]const u8,
    // The window title.
    title: [:0]const u8,
    // The window's width when the command line does not give one.
    default_width: c_int,
    // The window's height when the command line does not give one.
    default_height: c_int,
    // The PNG file of the window icon, or null when the app has none and the window shows the desktop's generic one.
    icon_png: ?[]const u8,
    // The files of the app's bundled page, embedded in the executable. One of them must be "index.html".
    ui_files: []const ui_files.UiFile,
};

//
// A message from the core, waiting to be delivered to the page.
//
const PendingMessage = struct {
    // The JSON text of the message.
    text: []u8,
};

//
// Everything one running shell owns. It lives on the stack of run and every callback is given its address.
//
const Shell = struct {
    // What the app asked for.
    app_config: AppConfig,
    // The GTK application.
    application: *c.GtkApplication,
    // The command line, for the geometry option.
    args: []const [:0]const u8,
    // The web view, once the window exists.
    web_view: ?*c.WebKitWebView,
    // The core's handle, until it is destroyed.
    core: ?*anyopaque,
    // Messages from the core waiting for the main thread.
    queue: *c.GAsyncQueue,
    // Set when the core has been destroyed, so nothing more is delivered.
    destroyed: std.atomic.Value(bool),
    // Whether a test hooks build was started in test mode.
    test_mode: bool,
    // The window, once it exists.
    window: ?*c.GtkWindow,
    // Holds the menu's parsed text and the context of each menu item, for as long as the menu lives.
    menu_arena: std.heap.ArenaAllocator,
    // Whether the developer tools window is showing.
    inspector_open: bool,
    // Whether the window is full screen.
    fullscreen: bool,
    // How many holds on the computer staying awake are in place. Only the main thread touches it.
    awake_holds: u32,
    // The cookie of the suspend inhibit, while there is one.
    inhibit_cookie: c_uint,
};

//
// Runs the app and returns the process's exit code.
//
pub fn run(app_config: AppConfig, args: []const [:0]const u8) !u8 {
    const application = c.gtk_application_new(app_config.app_id.ptr, c.G_APPLICATION_NON_UNIQUE) orelse {
        return error.GtkApplicationFailed;
    };
    defer c.g_object_unref(application);
    var shell = Shell{
        .app_config = app_config,
        .application = application,
        .args = args,
        .web_view = null,
        .core = null,
        .queue = c.g_async_queue_new() orelse return error.OutOfMemory,
        .destroyed = .init(false),
        .test_mode = false,
        .window = null,
        .menu_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator),
        .inspector_open = false,
        .fullscreen = false,
        .awake_holds = 0,
        .inhibit_cookie = 0,
    };
    defer c.g_async_queue_unref(shell.queue);
    _ = c.g_signal_connect_data(application, "activate", @ptrCast(&onActivate), &shell, null, 0);
    _ = c.g_signal_connect_data(application, "shutdown", @ptrCast(&onShutdown), &shell, null, 0);
    const status = c.g_application_run(@ptrCast(application), 0, null);
    if (status < 0 or status > 255) {
        return error.GtkApplicationFailed;
    }
    return @intCast(status);
}

//
// Sets the window's icon from the bytes of a PNG file.
//
fn setWindowIcon(window: *c.GtkWindow, icon_png: []const u8) void {
    const loader = c.gdk_pixbuf_loader_new_with_type("png", null) orelse {
        fatal("could not create the icon loader", .{});
    };
    defer c.g_object_unref(loader);
    if (c.gdk_pixbuf_loader_write(loader, icon_png.ptr, icon_png.len, null) == 0) {
        fatal("could not read the window icon", .{});
    }
    if (c.gdk_pixbuf_loader_close(loader, null) == 0) {
        fatal("could not finish reading the window icon", .{});
    }
    c.gtk_window_set_icon(window, c.gdk_pixbuf_loader_get_pixbuf(loader));
}

//
// Says why the shell cannot go on and ends the program with a failure code.
//
fn fatal(comptime format: []const u8, arguments: anytype) noreturn {
    std.debug.print("ziggy shell: " ++ format ++ "\n", arguments);
    std.process.exit(1);
}

//
// WebKitGTK runs its web process in a bubblewrap sandbox, which needs the program to be allowed to create a user
// namespace. Some systems do not allow that to an ordinary program (Ubuntu's default restriction on user namespaces is one),
// and the web view then cannot start at all. This runs the same bubblewrap setup WebKitGTK does, and when it fails turns the
// sandbox off for this process through the environment variable WebKitGTK documents for it, and says so on standard error.
// The app loads only its own bundled page and refuses every other navigation, which is what limits what runs without the
// sandbox. A setting made in the environment is left alone, so it can still be set either way from outside.
//
fn turnSandboxOffWhenItCannotStart() !void {
    if (c.g_getenv("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS") != null) {
        return;
    }
    if (c.system("bwrap --ro-bind / / --unshare-user true > /dev/null 2>&1") == 0) {
        return;
    }
    std.debug.print("ziggy shell: the web view's sandbox cannot start on this system (bubblewrap is not allowed to create a user namespace), so it is turned off for this run.\n", .{});
    if (c.setenv("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS", "1", 1) != 0) {
        return error.SetEnvironmentFailed;
    }
}

//
// Answers a web view request for one of the bundled page's files, from the files embedded in the executable. A path that
// is not one of them is answered with a not found error.
//
fn onUriSchemeRequest(request: *c.WebKitURISchemeRequest, user_data: c.gpointer) callconv(.c) void {
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    const request_path = std.mem.span(c.webkit_uri_scheme_request_get_path(request));
    const file = ui_files.findFile(shell.app_config.ui_files, request_path) orelse {
        const not_found = c.g_error_new_literal(c.g_io_error_quark(), c.G_IO_ERROR_NOT_FOUND, "the page has no such file");
        c.webkit_uri_scheme_request_finish_error(request, not_found);
        c.g_error_free(not_found);
        return;
    };
    // The bytes live in the executable for as long as it runs, so the stream is told not to free them.
    const stream = c.g_memory_input_stream_new_from_data(file.content.ptr, @intCast(file.content.len), null);
    c.webkit_uri_scheme_request_finish(request, stream, @intCast(file.content.len), ui_files.contentType(file.path).ptr);
    c.g_object_unref(stream);
}

//
// GTK calls this when the application starts: creates the window and the web view.
//
fn onActivate(application: *c.GtkApplication, user_data: ?*anyopaque) callconv(.c) void {
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    start(shell, application) catch |err| {
        fatal("could not start: {s}", .{@errorName(err)});
    };
}

//
// Creates the window and the web view, creates the core and loads the page.
//
fn start(shell: *Shell, application: *c.GtkApplication) !void {
    const test_hooks = z.ziggy_test_hooks_enabled();
    shell.test_mode = test_hooks and c.g_getenv("ZIGGY_TEST_MODE") != null;

    if (ui_files.findFile(shell.app_config.ui_files, "/") == null) {
        return error.UiHasNoIndexPage;
    }
    // The page's own scripts are classic scripts, but a page may also fetch its files, which needs the scheme to be
    // allowed to make cross-origin style requests and to count as a secure context like https does.
    const web_context = c.webkit_web_context_get_default();
    c.webkit_web_context_register_uri_scheme(web_context, app_scheme, onUriSchemeRequest, shell, null);
    const security_manager = c.webkit_web_context_get_security_manager(web_context);
    c.webkit_security_manager_register_uri_scheme_as_secure(security_manager, app_scheme);
    c.webkit_security_manager_register_uri_scheme_as_cors_enabled(security_manager, app_scheme);

    const data_directory = c.g_build_filename(c.g_get_user_data_dir(), shell.app_config.app_id.ptr, @as([*c]const u8, null));
    defer c.g_free(data_directory);
    if (c.g_mkdir_with_parents(data_directory, 0o755) != 0) {
        return error.DataDirectoryFailed;
    }

    var width = shell.app_config.default_width;
    var height = shell.app_config.default_height;
    for (shell.args) |argument| {
        if (std.mem.startsWith(u8, argument, "-geometry=")) {
            const geometry = geometry_lib.parseGeometry(argument["-geometry=".len..]) orelse {
                return error.InvalidGeometry;
            };
            width = geometry.width;
            height = geometry.height;
        }
    }

    const window_widget = c.gtk_application_window_new(application);
    const window: *c.GtkWindow = @ptrCast(@alignCast(window_widget));
    shell.window = window;
    c.gtk_window_set_title(window, shell.app_config.title.ptr);
    c.gtk_window_set_default_size(window, width, height);
    if (shell.app_config.icon_png) |icon_png| {
        setWindowIcon(window, icon_png);
    }

    try turnSandboxOffWhenItCannotStart();
    const web_view_widget = c.webkit_web_view_new();
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(web_view_widget));
    shell.web_view = web_view;
    c.webkit_settings_set_enable_developer_extras(c.webkit_web_view_get_settings(web_view), 1);
    _ = c.g_signal_connect_data(c.webkit_web_view_get_inspector(web_view), "closed", @ptrCast(&onInspectorClosed), shell, null, 0);
    const box_widget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_container_add(window_widget, box_widget);
    c.gtk_box_pack_start(box_widget, web_view_widget, 1, 1, 0);

    const content_manager = c.webkit_web_view_get_user_content_manager(web_view);
    if (c.webkit_user_content_manager_register_script_message_handler(content_manager, "ziggy") == 0) {
        return error.ScriptMessageHandlerFailed;
    }
    _ = c.g_signal_connect_data(content_manager, "script-message-received::ziggy", @ptrCast(&onScriptMessage), shell, null, 0);
    var inject_script_length: usize = 0;
    const inject_script = z.ziggy_inject_script(&inject_script_length);
    const user_script = c.webkit_user_script_new(@ptrCast(inject_script), c.WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, c.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, null, null);
    c.webkit_user_content_manager_add_script(content_manager, user_script);
    c.webkit_user_script_unref(user_script);
    _ = c.g_signal_connect_data(web_view, "decide-policy", @ptrCast(&onDecidePolicy), shell, null, 0);
    _ = c.g_signal_connect_data(window, "delete-event", @ptrCast(&onDeleteEvent), shell, null, 0);
    _ = c.g_signal_connect_data(web_view, "drag-data-received", @ptrCast(&onDragDataReceived), shell, null, 0);

    var config = std.mem.zeroes(z.ziggy_config);
    config.user_data = shell;
    config.deliver = deliver;
    config.os_version = osVersion;
    config.quit = quit;
    config.pick_paths = pickPaths;
    config.menu_action = menuAction;
    config.screenshot = screenshot;
    if (shell.app_config.host_request != null) {
        config.host_request = hostRequest;
    }
    config.worker_threads = c.g_get_num_processors();
    config.max_concurrent_child_tasks = 10;
    config.app_url_prefix = app_url_prefix;
    config.data_dir = data_directory;
    if (shell.test_mode) {
        config.test_mode = true;
        config.test_port_file = c.g_getenv("ZIGGY_TEST_PORT_FILE");
    }
    shell.core = z.ziggy_create(&config) orelse {
        return error.CoreCreateFailed;
    };

    try buildMenu(shell, box_widget, window);

    // The app supplies the query unread, and the core says nothing about its parts.
    var query_length: usize = 0;
    const query_pointer = z.ziggy_page_query(shell.core, &query_length) orelse {
        return error.PageQueryFailed;
    };
    const query = query_pointer[0..query_length];
    const query_separator: []const u8 = if (query.len > 0) "?" else "";
    const page_url = try std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s}index.html{s}{s}", .{ app_url_prefix, query_separator, query }, 0);
    defer std.heap.c_allocator.free(page_url);
    c.webkit_web_view_load_uri(web_view, page_url.ptr);
    c.gtk_widget_show_all(window_widget);
    c.gtk_window_present(window);
}

//
// A message from the page: hands it to the core.
//
fn onScriptMessage(content_manager: *c.WebKitUserContentManager, result: *c.WebKitJavascriptResult, user_data: ?*anyopaque) callconv(.c) void {
    _ = content_manager;
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    const core = shell.core orelse {
        return;
    };
    const text = c.jsc_value_to_string(c.webkit_javascript_result_get_js_value(result)) orelse {
        fatal("the page posted a message that is not a string", .{});
    };
    defer c.g_free(text);
    const slice = std.mem.span(@as([*:0]const u8, @ptrCast(text)));
    z.ziggy_post_message(core, slice.ptr, slice.len);
}

//
// Decides every navigation with the core's origin check: the app's own page loads, external links open in the system
// browser, and everything else is blocked.
//
fn onDecidePolicy(web_view: *c.WebKitWebView, decision: *c.WebKitPolicyDecision, decision_type: c.WebKitPolicyDecisionType, user_data: ?*anyopaque) callconv(.c) c.gboolean {
    _ = web_view;
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    if (decision_type != c.WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION and decision_type != c.WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
        return 0;
    }
    const navigation_decision: *c.WebKitNavigationPolicyDecision = @ptrCast(@alignCast(decision));
    const action = c.webkit_navigation_policy_decision_get_navigation_action(navigation_decision);
    const request = c.webkit_navigation_action_get_request(action);
    const uri = std.mem.span(@as([*:0]const u8, @ptrCast(c.webkit_uri_request_get_uri(request))));
    const verdict = z.ziggy_check_url(shell.core, uri.ptr, uri.len);
    if (verdict == z.ZIGGY_URL_ALLOW and decision_type == c.WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
        c.webkit_policy_decision_use(decision);
        return 1;
    }
    if (verdict == z.ZIGGY_URL_OPEN_EXTERNALLY) {
        _ = c.gtk_show_uri_on_window(null, uri.ptr, c.GDK_CURRENT_TIME, null);
    }
    c.webkit_policy_decision_ignore(decision);
    return 1;
}

//
// Records the files of a drop on the web view with the core, so the page can ask for their paths. WebKitGTK gives the page no files and
// hides the file addresses, so the paths can only be read here. This handler runs before WebKit's own, which is the default handler of
// the signal and runs last, so the paths are recorded before the page's drop is handled. Anything dropped that is not a file is ignored.
//
fn onDragDataReceived(widget: *c.GtkWidget, drag_context: *c.GdkDragContext, x: c_int, y: c_int, data: *c.GtkSelectionData, info: c_uint, time: c_uint, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    _ = drag_context;
    _ = x;
    _ = y;
    _ = info;
    _ = time;
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    const core = shell.core orelse {
        return;
    };
    const uris = c.gtk_selection_data_get_uris(data);
    if (uris == null) {
        return;
    }
    defer c.g_strfreev(uris);
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| {
            c.g_free(@ptrCast(@constCast(path.ptr)));
        }
        paths.deinit(std.heap.c_allocator);
    }
    var index: usize = 0;
    while (uris[index] != null) : (index += 1) {
        const path = c.g_filename_from_uri(uris[index], null, null);
        if (path == null) {
            continue;
        }
        paths.append(std.heap.c_allocator, std.mem.span(@as([*:0]const u8, @ptrCast(path)))) catch @panic("out of memory recording a drop");
    }
    const json = std.json.Stringify.valueAlloc(std.heap.c_allocator, paths.items, .{}) catch @panic("out of memory recording a drop");
    defer std.heap.c_allocator.free(json);
    if (!z.ziggy_files_dropped(core, json.ptr, json.len)) {
        std.debug.print("could not record the dropped files: {s}\n", .{json});
    }
}

//
// The window is being closed: destroys the core before the window goes.
//
fn onDeleteEvent(window: *c.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) c.gboolean {
    _ = event;
    _ = window;
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    destroyCore(shell);
    return 0;
}

//
// The application is shutting down: destroys the core if it still exists and discards the messages that were never delivered.
//
fn onShutdown(application: *c.GApplication, user_data: ?*anyopaque) callconv(.c) void {
    _ = application;
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    destroyCore(shell);
    discardPending(shell);
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
    z.ziggy_destroy(core);
}

//
// Frees the messages queued for the page that were never delivered.
//
fn discardPending(shell: *Shell) void {
    while (c.g_async_queue_try_pop(shell.queue)) |item| {
        const pending: *PendingMessage = @ptrCast(@alignCast(item));
        std.heap.c_allocator.free(pending.text);
        std.heap.c_allocator.destroy(pending);
    }
}

//
// The core's deliver callback. It runs on any thread: it queues the message and asks the main thread to deliver it.
//
fn deliver(user_data: ?*anyopaque, message: [*c]const u8, message_len: usize) callconv(.c) void {
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    if (shell.destroyed.load(.acquire)) {
        return;
    }
    const pending = std.heap.c_allocator.create(PendingMessage) catch @panic("out of memory delivering a message");
    pending.text = std.heap.c_allocator.dupe(u8, message[0..message_len]) catch @panic("out of memory delivering a message");
    c.g_async_queue_push(shell.queue, pending);
    _ = c.g_idle_add(drainQueue, shell);
}

//
// Runs on the main thread: sends every queued message to the page, in the order they were queued.
//
fn drainQueue(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    while (c.g_async_queue_try_pop(shell.queue)) |item| {
        const pending: *PendingMessage = @ptrCast(@alignCast(item));
        defer {
            std.heap.c_allocator.free(pending.text);
            std.heap.c_allocator.destroy(pending);
        }
        if (shell.destroyed.load(.acquire)) {
            continue;
        }
        const web_view = shell.web_view orelse {
            fatal("a message arrived from the core before the web view existed", .{});
        };
        const script = std.mem.concat(std.heap.c_allocator, u8, &.{ "window.__ziggyReceive(", pending.text, ");" }) catch @panic("out of memory delivering a message");
        defer std.heap.c_allocator.free(script);
        c.webkit_web_view_evaluate_javascript(web_view, script.ptr, @intCast(script.len), null, null, null, null, null);
    }
    return 0;
}

//
// The native host callback that answers the operating system's version.
//
fn osVersion(user_data: ?*anyopaque, buffer: [*c]u8, capacity: usize) callconv(.c) isize {
    _ = user_data;
    var info: std.c.utsname = undefined;
    if (std.c.uname(&info) != 0) {
        return -1;
    }
    var version_buffer: [256]u8 = undefined;
    const version = std.fmt.bufPrint(&version_buffer, "{s} {s} {s}", .{
        std.mem.sliceTo(&info.sysname, 0),
        std.mem.sliceTo(&info.release, 0),
        std.mem.sliceTo(&info.machine, 0),
    }) catch {
        return -1;
    };
    // The version is written as a JSON string, so the JSON writer does the quoting and escaping.
    const written = std.fmt.bufPrint(buffer[0..capacity], "{f}", .{std.json.fmt(version, .{})}) catch {
        return -1;
    };
    return @intCast(written.len);
}

//
// The native host callback that does one thing only the platform can do, by handing it to the app's handler. Writes the answer into
// the core's buffer and returns its length, or writes the reason and returns its length negated.
//
fn hostRequest(user_data: ?*anyopaque, method: [*c]const u8, request_json: [*c]const u8, buffer: [*c]u8, capacity: usize) callconv(.c) isize {
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    const handler = shell.app_config.host_request.?;
    const method_name = std.mem.span(@as([*:0]const u8, @ptrCast(method)));
    const request = std.mem.span(@as([*:0]const u8, @ptrCast(request_json)));
    var reason_buffer: [256]u8 = undefined;
    var failed = false;
    const answer: []const u8 = blk: {
        const maybe_answer = handler(.{ .shell = shell }, method_name, request) catch |err| {
            failed = true;
            break :blk std.fmt.bufPrint(&reason_buffer, "The request {s} failed: {s}", .{ method_name, @errorName(err) }) catch "The request failed.";
        };
        if (maybe_answer) |text| {
            break :blk text;
        }
        failed = true;
        break :blk std.fmt.bufPrint(&reason_buffer, "The Photosphere Linux app cannot do \"{s}\".", .{method_name}) catch "The request is not known.";
    };
    if (answer.len > capacity) {
        return -1;
    }
    @memcpy(buffer[0..answer.len], answer);
    const length: isize = @intCast(answer.len);
    return if (failed) -length else length;
}

//
// Takes one hold on the computer staying awake, run on the main thread. The first one inhibits suspend.
//
fn holdAwakeOnMainThread(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    shell.awake_holds += 1;
    if (shell.awake_holds == 1) {
        shell.inhibit_cookie = c.gtk_application_inhibit(shell.application, shell.window, c.GTK_APPLICATION_INHIBIT_SUSPEND, "Photosphere is working in the background");
    }
    return 0;
}

//
// Lets go of one hold on the computer staying awake, run on the main thread. Letting go of the last one allows suspend again.
//
fn releaseAwakeOnMainThread(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    if (shell.awake_holds == 0) {
        fatal("a hold on the computer staying awake was let go that was never taken", .{});
    }
    shell.awake_holds -= 1;
    if (shell.awake_holds == 0 and shell.inhibit_cookie != 0) {
        c.gtk_application_uninhibit(shell.application, shell.inhibit_cookie);
        shell.inhibit_cookie = 0;
    }
    return 0;
}

//
// The native host callback that quits the application, asked for by the test control connection. It can be called from any
// thread, so the quit happens on the main thread.
//
fn quit(user_data: ?*anyopaque) callconv(.c) void {
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    _ = c.g_idle_add(quitOnMainThread, shell);
}

//
// Quits the application, run on the main thread.
//
fn quitOnMainThread(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    c.g_application_quit(@ptrCast(shell.application));
    return 0;
}

//
// One menu item's action, kept for as long as the menu lives.
//
const MenuItemContext = struct {
    // The shell the item belongs to.
    shell: *Shell,
    // The item's action.
    action: [:0]const u8,
};

//
// Builds the menu bar from the app's menu, which the core holds as JSON, and puts it above the web view. An app with no menu
// gets no menu bar. Every item's shortcut is registered with the window, so it works wherever the focus is.
//
fn buildMenu(shell: *Shell, box_widget: *c.GtkWidget, window: *c.GtkWindow) !void {
    var length: usize = 0;
    const text_pointer = z.ziggy_menu_json(shell.core, &length);
    const arena = shell.menu_arena.allocator();
    const menus = try std.json.parseFromSliceLeaky(std.json.Value, arena, text_pointer[0..length], .{});
    if (menus != .array) {
        return error.MenuIsNotAnArray;
    }
    if (menus.array.items.len == 0) {
        return;
    }
    const accel_group = c.gtk_accel_group_new();
    c.gtk_window_add_accel_group(window, accel_group);
    const menu_bar = c.gtk_menu_bar_new();
    for (menus.array.items) |menu| {
        const menu_item = c.gtk_menu_item_new_with_label(try requireString(arena, menu, "label"));
        const submenu = c.gtk_menu_new();
        try appendItems(shell, submenu, accel_group, menu);
        c.gtk_menu_item_set_submenu(menu_item, submenu);
        c.gtk_menu_shell_append(menu_bar, menu_item);
    }
    c.gtk_box_pack_start(box_widget, menu_bar, 0, 0, 0);
    c.gtk_box_reorder_child(box_widget, menu_bar, 0);
}

//
// Adds the "items" of a menu or submenu to a GTK menu.
//
fn appendItems(shell: *Shell, gtk_menu: *c.GtkWidget, accel_group: *c.GtkAccelGroup, menu: std.json.Value) !void {
    const arena = shell.menu_arena.allocator();
    const items = menu.object.get("items") orelse {
        return error.MenuHasNoItems;
    };
    for (items.array.items) |item| {
        if (item.object.get("separator") != null) {
            c.gtk_menu_shell_append(gtk_menu, c.gtk_separator_menu_item_new());
            continue;
        }
        const menu_item = c.gtk_menu_item_new_with_label(try requireString(arena, item, "label"));
        if (item.object.get("items") != null) {
            const submenu = c.gtk_menu_new();
            try appendItems(shell, submenu, accel_group, item);
            c.gtk_menu_item_set_submenu(menu_item, submenu);
        }
        else {
            const context = try arena.create(MenuItemContext);
            context.* = .{
                .shell = shell,
                .action = try requireString(arena, item, "action"),
            };
            _ = c.g_signal_connect_data(menu_item, "activate", @ptrCast(&onMenuItemActivate), context, null, 0);
            if (item.object.get("accelerator")) |accelerator_text| {
                try addAccelerator(arena, menu_item, accel_group, accelerator_text.string);
            }
        }
        c.gtk_menu_shell_append(gtk_menu, menu_item);
    }
}

//
// Registers a menu item's keyboard shortcut with the window.
//
fn addAccelerator(arena: std.mem.Allocator, menu_item: *c.GtkWidget, accel_group: *c.GtkAccelGroup, text: []const u8) !void {
    var parsed: z.ziggy_accelerator = undefined;
    if (!z.ziggy_parse_accelerator(text.ptr, text.len, &parsed)) {
        std.debug.print("ziggy shell: the menu has a shortcut that cannot be read: {s}\n", .{text});
        return error.UnreadableShortcut;
    }
    _ = arena;
    var name_buffer: [32]u8 = undefined;
    const key_name = try menu_keys.gdkKeyName(&name_buffer, std.mem.sliceTo(&parsed.key, 0));
    const key_value = c.gdk_keyval_from_name(key_name.ptr);
    if (key_value == 0) {
        std.debug.print("ziggy shell: GTK has no key named {s}, for the shortcut {s}\n", .{ key_name, text });
        return error.UnknownKey;
    }
    c.gtk_widget_add_accelerator(menu_item, "activate", accel_group, key_value, menu_keys.gdkModifiers(parsed.modifiers), c.GTK_ACCEL_VISIBLE);
}

//
// Reads a string field of a menu entry, as a NUL terminated copy that lives as long as the menu.
//
fn requireString(arena: std.mem.Allocator, entry: std.json.Value, name: []const u8) ![:0]const u8 {
    const field = entry.object.get(name) orelse {
        std.debug.print("ziggy shell: a menu entry has no \"{s}\"\n", .{name});
        return error.MenuEntryIncomplete;
    };
    return try arena.dupeZ(u8, field.string);
}

//
// A menu item was chosen: does its action.
//
fn onMenuItemActivate(menu_item: *c.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = menu_item;
    const context: *MenuItemContext = @ptrCast(@alignCast(user_data.?));
    performAction(context.shell, context.action) catch |err| {
        fatal("could not do the menu action {s}: {s}", .{ context.action, @errorName(err) });
    };
}

//
// Does a menu action. The actions every shell does itself are done here, and any other is the app's, which goes to the core to
// be handed to the page.
//
fn performAction(shell: *Shell, action: []const u8) !void {
    const web_view = shell.web_view.?;
    if (std.mem.eql(u8, action, "quit")) {
        c.g_application_quit(@ptrCast(shell.application));
    }
    else if (std.mem.eql(u8, action, "close-window")) {
        c.gtk_window_close(shell.window.?);
    }
    else if (std.mem.eql(u8, action, "reload")) {
        c.webkit_web_view_reload(web_view);
    }
    else if (std.mem.eql(u8, action, "toggle-devtools")) {
        const inspector = c.webkit_web_view_get_inspector(web_view);
        if (shell.inspector_open) {
            c.webkit_web_inspector_close(inspector);
        }
        else {
            c.webkit_web_inspector_show(inspector);
            shell.inspector_open = true;
        }
    }
    else if (std.mem.eql(u8, action, "toggle-fullscreen")) {
        if (shell.fullscreen) {
            c.gtk_window_unfullscreen(shell.window.?);
        }
        else {
            c.gtk_window_fullscreen(shell.window.?);
        }
        shell.fullscreen = !shell.fullscreen;
    }
    else if (std.mem.eql(u8, action, "zoom-in")) {
        c.webkit_web_view_set_zoom_level(web_view, @min(5.0, c.webkit_web_view_get_zoom_level(web_view) + 0.1));
    }
    else if (std.mem.eql(u8, action, "zoom-out")) {
        c.webkit_web_view_set_zoom_level(web_view, @max(0.25, c.webkit_web_view_get_zoom_level(web_view) - 0.1));
    }
    else if (std.mem.eql(u8, action, "zoom-reset")) {
        c.webkit_web_view_set_zoom_level(web_view, 1.0);
    }
    else if (std.mem.eql(u8, action, "focus-window")) {
        c.gtk_window_present(shell.window.?);
    }
    else if (editingCommand(action)) |command| {
        c.webkit_web_view_execute_editing_command(web_view, command);
    }
    else {
        const message = try std.json.Stringify.valueAlloc(std.heap.c_allocator, .{
            .channel = "menu-action",
            .data = .{
                .action = action,
            },
        }, .{});
        defer std.heap.c_allocator.free(message);
        z.ziggy_post_message(shell.core, message.ptr, message.len);
    }
}

//
// The WebKit editing command for a menu action that edits, or null for any other action.
//
fn editingCommand(action: []const u8) ?[*:0]const u8 {
    if (std.mem.eql(u8, action, "undo")) {
        return "Undo";
    }
    if (std.mem.eql(u8, action, "redo")) {
        return "Redo";
    }
    if (std.mem.eql(u8, action, "cut")) {
        return "Cut";
    }
    if (std.mem.eql(u8, action, "copy")) {
        return "Copy";
    }
    if (std.mem.eql(u8, action, "paste")) {
        return "Paste";
    }
    if (std.mem.eql(u8, action, "select-all")) {
        return "SelectAll";
    }
    return null;
}

//
// The developer tools window was closed by the user, so the next toggle opens it again.
//
fn onInspectorClosed(inspector: *c.WebKitWebInspector, user_data: ?*anyopaque) callconv(.c) void {
    _ = inspector;
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    shell.inspector_open = false;
}

//
// One request for a native dialog, made on a worker thread and answered on the main thread. It lives on the worker's stack
// for as long as the worker waits.
//
const PickRequest = struct {
    // The shell the dialog belongs to.
    shell: *Shell,
    // What to show, a ZIGGY_PICK_ value.
    kind: i32,
    // The dialog's title, or null.
    title: ?[*:0]const u8,
    // The suggested file name for a save, or null.
    initial_name: ?[*:0]const u8,
    // Where the answer goes.
    buffer: [*]u8,
    // The size of that buffer.
    capacity: usize,
    // The number of bytes written to the buffer, or a negative number when the dialog could not be shown or the answer did not fit.
    result: isize,
    // The Io the worker waits with.
    io: std.Io,
    // Set when the main thread has answered.
    answered: std.Io.Event,
};

//
// The native host callback that shows a file or folder dialog. It runs on a worker thread: it asks the main thread to show the
// dialog and waits for the answer, so the window stays responsive while the dialog is up.
//
fn pickPaths(user_data: ?*anyopaque, kind: i32, title: ?[*:0]const u8, initial_name: ?[*:0]const u8, buffer: [*c]u8, capacity: usize) callconv(.c) isize {
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    var threaded: std.Io.Threaded = .init_single_threaded;
    var request = PickRequest{
        .shell = shell,
        .kind = kind,
        .title = title,
        .initial_name = initial_name,
        .buffer = buffer,
        .capacity = capacity,
        .result = -1,
        .io = threaded.io(),
        .answered = .unset,
    };
    _ = c.g_idle_add(showPickDialog, &request);
    request.answered.waitUncancelable(request.io);
    return request.result;
}

//
// Runs on the main thread: shows the dialog, waits for the user, and writes the paths chosen as a JSON array.
//
fn showPickDialog(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    const request: *PickRequest = @ptrCast(@alignCast(user_data.?));
    request.result = runPickDialog(request) catch |err| blk: {
        std.debug.print("ziggy shell: the dialog failed: {s}\n", .{@errorName(err)});
        break :blk -1;
    };
    request.answered.set(request.io);
    return 0;
}

//
// Shows the dialog and returns the number of bytes of the answer written to the request's buffer.
//
fn runPickDialog(request: *PickRequest) !isize {
    const action: c_int = switch (request.kind) {
        z.ZIGGY_PICK_OPEN_FILES => c.GTK_FILE_CHOOSER_ACTION_OPEN,
        z.ZIGGY_PICK_SAVE_FILE => c.GTK_FILE_CHOOSER_ACTION_SAVE,
        z.ZIGGY_PICK_FOLDER => c.GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
        else => return error.UnknownDialogKind,
    };
    const default_title: [*:0]const u8 = switch (request.kind) {
        z.ZIGGY_PICK_OPEN_FILES => "Select Files",
        z.ZIGGY_PICK_SAVE_FILE => "Save As",
        else => "Select Folder",
    };
    const dialog = c.gtk_file_chooser_native_new(request.title orelse default_title, request.shell.window, action, null, null);
    defer c.g_object_unref(dialog);
    if (request.kind == z.ZIGGY_PICK_OPEN_FILES) {
        c.gtk_file_chooser_set_select_multiple(dialog, 1);
    }
    if (request.kind == z.ZIGGY_PICK_SAVE_FILE) {
        c.gtk_file_chooser_set_do_overwrite_confirmation(dialog, 1);
        if (request.initial_name) |name| {
            c.gtk_file_chooser_set_current_name(dialog, name);
        }
    }
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(std.heap.c_allocator);
    if (c.gtk_native_dialog_run(dialog) == c.GTK_RESPONSE_ACCEPT) {
        const list = c.gtk_file_chooser_get_filenames(dialog);
        defer c.g_slist_free(list);
        var node = list;
        while (node) |entry| : (node = entry.next) {
            try paths.append(std.heap.c_allocator, std.mem.span(@as([*:0]const u8, @ptrCast(entry.data.?))));
        }
        const json = try std.json.Stringify.valueAlloc(std.heap.c_allocator, paths.items, .{});
        defer std.heap.c_allocator.free(json);
        // The file names are owned by GTK until they are freed, which happens after the JSON is built and copied.
        return try copyAnswer(request, json);
    }
    return try copyAnswer(request, "[]");
}

//
// Copies the answer into the request's buffer, or fails when it does not fit, and returns its length.
//
fn copyAnswer(request: *PickRequest, json: []const u8) !isize {
    if (json.len > request.capacity) {
        return error.AnswerDoesNotFit;
    }
    @memcpy(request.buffer[0..json.len], json);
    return @intCast(json.len);
}

//
// A menu action chosen by a test, handed from the test control connection's thread to the main thread.
//
const MenuActionRequest = struct {
    // The shell the menu belongs to.
    shell: *Shell,
    // The action, as a NUL terminated copy owned by the request.
    action: [:0]u8,
};

//
// The native host callback that does a menu action as if its menu item had been chosen: it hands the action to the main thread,
// which runs the same function a menu item runs.
//
fn menuAction(user_data: ?*anyopaque, action: [*c]const u8) callconv(.c) void {
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    const request = std.heap.c_allocator.create(MenuActionRequest) catch @panic("out of memory choosing a menu item");
    request.shell = shell;
    request.action = std.heap.c_allocator.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(action)))) catch @panic("out of memory choosing a menu item");
    _ = c.g_idle_add(runMenuAction, request);
}

//
// Does a menu action asked for from another thread, run on the main thread, and frees the request.
//
fn runMenuAction(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    const request: *MenuActionRequest = @ptrCast(@alignCast(user_data.?));
    performAction(request.shell, request.action) catch |err| {
        fatal("could not do the menu action {s}: {s}", .{ request.action, @errorName(err) });
    };
    std.heap.c_allocator.free(request.action);
    std.heap.c_allocator.destroy(request);
    return 0;
}

//
// One request for a picture of the window, made on the thread of the test control connection and answered on the main thread. It
// lives on that thread's stack for as long as it waits.
//
const ScreenshotRequest = struct {
    // The shell whose window is captured.
    shell: *Shell,
    // The file to write the PNG to.
    output_path: [*:0]const u8,
    // Where the reason goes when the picture cannot be taken.
    buffer: [*]u8,
    // The size of that buffer.
    capacity: usize,
    // 0 when the file was written, or the number of bytes of the reason written to the buffer, negated.
    result: isize,
    // The Io the waiting thread waits with.
    io: std.Io,
    // Set when the main thread has answered.
    answered: std.Io.Event,
};

//
// The native host callback that writes a PNG of the window to a file. It runs on the thread of the test control connection: it asks
// the main thread to take the picture with the web view's own snapshot function and waits until the file is written.
//
fn screenshot(user_data: ?*anyopaque, output_path: [*c]const u8, buffer: [*c]u8, capacity: usize) callconv(.c) isize {
    const shell: *Shell = @ptrCast(@alignCast(user_data.?));
    var threaded: std.Io.Threaded = .init_single_threaded;
    var request = ScreenshotRequest{
        .shell = shell,
        .output_path = @ptrCast(output_path),
        .buffer = buffer,
        .capacity = capacity,
        .result = 0,
        .io = threaded.io(),
        .answered = .unset,
    };
    _ = c.g_idle_add(startScreenshot, &request);
    request.answered.waitUncancelable(request.io);
    return request.result;
}

//
// Runs on the main thread: asks the web view for a snapshot of what its window shows.
//
fn startScreenshot(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    const request: *ScreenshotRequest = @ptrCast(@alignCast(user_data.?));
    const web_view = request.shell.web_view orelse {
        finishScreenshot(request, "the window has no web view yet", .{});
        return 0;
    };
    c.webkit_web_view_get_snapshot(web_view, c.WEBKIT_SNAPSHOT_REGION_VISIBLE, c.WEBKIT_SNAPSHOT_OPTIONS_NONE, null, onSnapshot, request);
    return 0;
}

//
// Runs on the main thread when the web view has made the snapshot: writes it as a PNG and answers the waiting thread.
//
fn onSnapshot(source: c.gpointer, result: *c.GAsyncResult, user_data: c.gpointer) callconv(.c) void {
    const request: *ScreenshotRequest = @ptrCast(@alignCast(user_data.?));
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(source.?));
    var snapshot_error: ?*c.GError = null;
    const surface = c.webkit_web_view_get_snapshot_finish(web_view, result, &snapshot_error) orelse {
        const fields: *const c.GErrorFields = @ptrCast(@alignCast(snapshot_error.?));
        finishScreenshot(request, "the web view could not make a snapshot: {s}", .{std.mem.span(fields.message)});
        c.g_error_free(snapshot_error.?);
        return;
    };
    defer c.cairo_surface_destroy(surface);
    const status = c.cairo_surface_write_to_png(surface, request.output_path);
    if (status != c.CAIRO_STATUS_SUCCESS) {
        finishScreenshot(request, "could not write the PNG to {s}: {s}", .{ std.mem.span(request.output_path), std.mem.span(c.cairo_status_to_string(status)) });
        return;
    }
    request.result = 0;
    request.answered.set(request.io);
}

//
// Answers the waiting thread that the picture could not be taken, with the reason written into its buffer. A reason too long for the
// buffer is cut to fit.
//
fn finishScreenshot(request: *ScreenshotRequest, comptime format: []const u8, arguments: anytype) void {
    const reason = std.fmt.bufPrint(request.buffer[0..request.capacity], format, arguments) catch request.buffer[0..request.capacity];
    request.result = -@as(isize, @intCast(reason.len));
    request.answered.set(request.io);
}
