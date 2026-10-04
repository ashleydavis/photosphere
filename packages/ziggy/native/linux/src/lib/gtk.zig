//
// The declarations of the GLib, GTK 3 and WebKitGTK 4.1 functions the shell calls, and the types and constants they use.
//
// These are declarations of the real libraries' functions, which the build links. They are written out here because
// Zig's C header translator cannot read GLib's headers: they use compiler pragma macros it does not understand. Only what
// the shell uses is declared, and each is checked against the library's own header documentation.
//

pub const gboolean = c_int;
pub const gpointer = ?*anyopaque;

pub const GApplication = opaque {};
pub const GtkApplication = opaque {};
pub const GtkWidget = opaque {};
pub const GtkWindow = opaque {};
pub const GAsyncQueue = opaque {};
pub const GError = opaque {};
pub const WebKitWebView = opaque {};
pub const WebKitUserContentManager = opaque {};
pub const WebKitUserScript = opaque {};
pub const WebKitPolicyDecision = opaque {};
pub const WebKitNavigationPolicyDecision = opaque {};
pub const WebKitNavigationAction = opaque {};
pub const WebKitURIRequest = opaque {};
pub const JSCValue = opaque {};
pub const WebKitJavascriptResult = opaque {};

// A GCallback: the signal handler's real type is cast to this when connecting.
// A WebKitPolicyDecisionType.
pub const WebKitPolicyDecisionType = c_uint;

// A GCallback: the signal handler's real type is cast to this when connecting.
pub const GCallback = ?*const fn () callconv(.c) void;
pub const GSourceFunc = *const fn (user_data: gpointer) callconv(.c) gboolean;

// GApplicationFlags: G_APPLICATION_NON_UNIQUE lets several copies run at once.
pub const G_APPLICATION_NON_UNIQUE: c_uint = 1 << 5;

// WebKitUserContentInjectedFrames: WEBKIT_USER_CONTENT_INJECT_TOP_FRAME.
pub const WEBKIT_USER_CONTENT_INJECT_TOP_FRAME: c_uint = 1;

// WebKitUserScriptInjectionTime: WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START.
pub const WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START: c_uint = 0;

// WebKitPolicyDecisionType.
pub const WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION: c_uint = 0;
pub const WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION: c_uint = 1;

// GDK_CURRENT_TIME.
pub const GDK_CURRENT_TIME: u32 = 0;

pub extern fn g_object_unref(object: gpointer) void;
pub extern fn g_signal_connect_data(instance: gpointer, detailed_signal: [*:0]const u8, handler: GCallback, data: gpointer, destroy_data: gpointer, connect_flags: c_uint) c_ulong;
pub extern fn g_application_run(application: *GApplication, argc: c_int, argv: ?[*]?[*:0]u8) c_int;
pub extern fn g_application_quit(application: *GApplication) void;
pub extern fn g_async_queue_new() ?*GAsyncQueue;
pub extern fn g_async_queue_unref(queue: *GAsyncQueue) void;
pub extern fn g_async_queue_push(queue: *GAsyncQueue, data: gpointer) void;
pub extern fn g_async_queue_try_pop(queue: *GAsyncQueue) gpointer;
pub extern fn g_idle_add(function: GSourceFunc, data: gpointer) c_uint;
pub extern fn g_getenv(variable: [*:0]const u8) ?[*:0]const u8;
pub extern fn g_file_read_link(filename: [*:0]const u8, err: ?*?*GError) ?[*:0]u8;
pub extern fn g_path_get_dirname(file_name: [*:0]const u8) [*:0]u8;
pub extern fn g_build_filename(first_element: [*:0]const u8, ...) [*:0]u8;
pub extern fn g_filename_to_uri(filename: [*:0]const u8, hostname: ?[*:0]const u8, err: ?*?*GError) ?[*:0]u8;
pub extern fn g_free(memory: gpointer) void;
pub extern fn g_get_user_data_dir() [*:0]const u8;
pub extern fn g_mkdir_with_parents(pathname: [*:0]const u8, mode: c_int) c_int;
pub extern fn g_get_num_processors() c_uint;

pub extern fn gtk_application_new(application_id: [*:0]const u8, flags: c_uint) ?*GtkApplication;
pub extern fn gtk_application_window_new(application: *GtkApplication) *GtkWidget;
pub extern fn gtk_window_set_title(window: *GtkWindow, title: [*:0]const u8) void;
pub extern fn gtk_window_set_default_size(window: *GtkWindow, width: c_int, height: c_int) void;
pub extern fn gtk_container_add(container: *GtkWidget, widget: *GtkWidget) void;
pub extern fn gtk_widget_show_all(widget: *GtkWidget) void;
pub extern fn gtk_window_present(window: *GtkWindow) void;
pub extern fn gtk_show_uri_on_window(parent: ?*GtkWindow, uri: [*:0]const u8, timestamp: u32, err: ?*?*GError) gboolean;

pub extern fn webkit_web_view_new() *GtkWidget;
pub extern fn webkit_web_view_get_user_content_manager(web_view: *WebKitWebView) *WebKitUserContentManager;
pub extern fn webkit_web_view_load_uri(web_view: *WebKitWebView, uri: [*:0]const u8) void;
pub extern fn webkit_web_view_evaluate_javascript(web_view: *WebKitWebView, script: [*]const u8, length: isize, world_name: ?[*:0]const u8, source_uri: ?[*:0]const u8, cancellable: gpointer, callback: gpointer, user_data: gpointer) void;
pub extern fn webkit_user_content_manager_register_script_message_handler(manager: *WebKitUserContentManager, name: [*:0]const u8) gboolean;
pub extern fn webkit_javascript_result_get_js_value(js_result: *WebKitJavascriptResult) *JSCValue;
pub extern fn webkit_user_content_manager_add_script(manager: *WebKitUserContentManager, script: *WebKitUserScript) void;
pub extern fn webkit_user_script_new(source: [*:0]const u8, injected_frames: c_uint, injection_time: c_uint, allow_list: ?[*]const ?[*:0]const u8, block_list: ?[*]const ?[*:0]const u8) *WebKitUserScript;
pub extern fn webkit_user_script_unref(script: *WebKitUserScript) void;
pub extern fn webkit_navigation_policy_decision_get_navigation_action(decision: *WebKitNavigationPolicyDecision) *WebKitNavigationAction;
pub extern fn webkit_navigation_action_get_request(navigation: *WebKitNavigationAction) *WebKitURIRequest;
pub extern fn webkit_uri_request_get_uri(request: *WebKitURIRequest) [*:0]const u8;
pub extern fn webkit_policy_decision_use(decision: *WebKitPolicyDecision) void;
pub extern fn webkit_policy_decision_ignore(decision: *WebKitPolicyDecision) void;
pub extern fn jsc_value_to_string(value: *JSCValue) ?[*:0]u8;

pub extern fn system(command: [*:0]const u8) c_int;
pub extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;


pub const GtkAccelGroup = opaque {};
pub const WebKitWebInspector = opaque {};
pub const WebKitSettings = opaque {};

// GtkOrientation: GTK_ORIENTATION_VERTICAL.
pub const GTK_ORIENTATION_VERTICAL: c_int = 1;

// GtkAccelFlags: GTK_ACCEL_VISIBLE shows the shortcut beside the menu item.
pub const GTK_ACCEL_VISIBLE: c_uint = 1;

pub extern fn gtk_box_new(orientation: c_int, spacing: c_int) *GtkWidget;
pub extern fn gtk_box_pack_start(box: *GtkWidget, child: *GtkWidget, expand: gboolean, fill: gboolean, padding: c_uint) void;
pub extern fn gtk_menu_bar_new() *GtkWidget;
pub extern fn gtk_menu_new() *GtkWidget;
pub extern fn gtk_menu_item_new_with_label(label: [*:0]const u8) *GtkWidget;
pub extern fn gtk_menu_item_set_submenu(menu_item: *GtkWidget, submenu: *GtkWidget) void;
pub extern fn gtk_menu_shell_append(menu_shell: *GtkWidget, child: *GtkWidget) void;
pub extern fn gtk_separator_menu_item_new() *GtkWidget;
pub extern fn gtk_accel_group_new() *GtkAccelGroup;
pub extern fn gtk_window_add_accel_group(window: *GtkWindow, accel_group: *GtkAccelGroup) void;
pub extern fn gtk_widget_add_accelerator(widget: *GtkWidget, accel_signal: [*:0]const u8, accel_group: *GtkAccelGroup, accel_key: c_uint, accel_mods: c_uint, accel_flags: c_uint) void;
pub extern fn gtk_window_fullscreen(window: *GtkWindow) void;
pub extern fn gtk_window_unfullscreen(window: *GtkWindow) void;
pub extern fn gdk_keyval_from_name(keyval_name: [*:0]const u8) c_uint;
pub extern fn webkit_web_view_reload(web_view: *WebKitWebView) void;
pub extern fn webkit_web_view_get_zoom_level(web_view: *WebKitWebView) f64;
pub extern fn webkit_web_view_set_zoom_level(web_view: *WebKitWebView, zoom_level: f64) void;
pub extern fn webkit_web_view_execute_editing_command(web_view: *WebKitWebView, command: [*:0]const u8) void;
pub extern fn webkit_web_view_get_settings(web_view: *WebKitWebView) *WebKitSettings;
pub extern fn webkit_web_view_get_inspector(web_view: *WebKitWebView) *WebKitWebInspector;
pub extern fn webkit_settings_set_enable_developer_extras(settings: *WebKitSettings, enabled: gboolean) void;
pub extern fn webkit_web_inspector_show(inspector: *WebKitWebInspector) void;
pub extern fn webkit_web_inspector_close(inspector: *WebKitWebInspector) void;
pub extern fn gtk_box_reorder_child(box: *GtkWidget, child: *GtkWidget, position: c_int) void;

pub const GtkFileChooserNative = opaque {};

// A GSList: a singly linked list node, as GTK returns the file names of a dialog.
pub const GSList = extern struct {
    data: gpointer,
    next: ?*GSList,
};

// GtkFileChooserAction.
pub const GTK_FILE_CHOOSER_ACTION_OPEN: c_int = 0;
pub const GTK_FILE_CHOOSER_ACTION_SAVE: c_int = 1;
pub const GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER: c_int = 2;

// GtkResponseType: GTK_RESPONSE_ACCEPT, what a dialog returns when the user chose something.
pub const GTK_RESPONSE_ACCEPT: c_int = -3;

pub extern fn gtk_file_chooser_native_new(title: [*:0]const u8, parent: ?*GtkWindow, action: c_int, accept_label: ?[*:0]const u8, cancel_label: ?[*:0]const u8) *GtkFileChooserNative;
pub extern fn gtk_native_dialog_run(dialog: *GtkFileChooserNative) c_int;
pub extern fn gtk_file_chooser_set_select_multiple(chooser: *GtkFileChooserNative, select_multiple: gboolean) void;
pub extern fn gtk_file_chooser_set_current_name(chooser: *GtkFileChooserNative, name: [*:0]const u8) void;
pub extern fn gtk_file_chooser_set_do_overwrite_confirmation(chooser: *GtkFileChooserNative, do_overwrite_confirmation: gboolean) void;
pub extern fn gtk_file_chooser_get_filenames(chooser: *GtkFileChooserNative) ?*GSList;
pub extern fn g_slist_free(list: ?*GSList) void;
