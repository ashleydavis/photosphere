//
// The C interface to the core. An app calls exportApi with its own handlers and the functions below are exported
// from its library, so every shell reaches the core the same way. The declarations are in ziggy.h.
//

const std = @import("std");
const build_options = @import("build_options");
const types = @import("types.zig");
const core_module = @import("core.zig");
const accelerator = @import("accelerator.zig");
const ui_files = @import("ui-files.zig");
const inject_script = @import("inject-script.zig");

//
// What ziggy_ui_file gives back for a file of the bundled page. Laid out like ziggy_ui_file_result in ziggy.h.
//
const UiFileResult = extern struct {
    // The file's bytes, which stay valid for as long as the library is loaded.
    content: [*]const u8,
    // The number of bytes.
    content_length: usize,
    // The file's content type, NUL terminated, which stays valid for as long as the library is loaded.
    content_type: [*:0]const u8,
};

//
// Exports ziggy_create, ziggy_destroy, ziggy_post_message, ziggy_check_url and ziggy_test_hooks_enabled from the library
// that calls this, serving the given app handlers. It is called once, in a comptime block of the app's root file.
//
pub fn exportApi(comptime app: core_module.AppHandlers) void {
    const Api = struct {
        fn create(config: *const types.ZiggyConfig) callconv(.c) ?*core_module.Core {
            return core_module.Core.create(std.heap.smp_allocator, config.*, app) catch |err| {
                std.debug.print("ziggy_create failed: {s}\n", .{@errorName(err)});
                return null;
            };
        }

        fn destroy(handle: ?*core_module.Core) callconv(.c) void {
            const core = handle orelse {
                return;
            };
            core.destroy();
        }

        fn postMessage(handle: ?*core_module.Core, message_ptr: [*]const u8, message_len: usize) callconv(.c) void {
            const core = handle orelse {
                @panic("ziggy_post_message called with a null handle");
            };
            core.postMessage(message_ptr[0..message_len]);
        }

        fn checkUrl(handle: ?*core_module.Core, url_ptr: [*]const u8, url_len: usize) callconv(.c) i32 {
            const core = handle orelse {
                @panic("ziggy_check_url called with a null handle");
            };
            return @intFromEnum(core.checkUrl(url_ptr[0..url_len]));
        }

        fn menuJson(handle: ?*core_module.Core, length: *usize) callconv(.c) [*]const u8 {
            const core = handle orelse {
                @panic("ziggy_menu_json called with a null handle");
            };
            length.* = core.menu_json.len;
            return core.menu_json.ptr;
        }

        fn uiFile(handle: ?*core_module.Core, path_ptr: [*]const u8, path_len: usize, result: *UiFileResult) callconv(.c) bool {
            const core = handle orelse {
                @panic("ziggy_ui_file called with a null handle");
            };
            const file = core.uiFile(path_ptr[0..path_len]) orelse {
                return false;
            };
            result.* = .{
                .content = file.content.ptr,
                .content_length = file.content.len,
                .content_type = ui_files.contentType(file.path).ptr,
            };
            return true;
        }

        fn injectScript(length: *usize) callconv(.c) [*:0]const u8 {
            length.* = inject_script.text.len;
            return inject_script.text.ptr;
        }

        fn parseAccelerator(text_ptr: [*]const u8, text_len: usize, result: *accelerator.Accelerator) callconv(.c) bool {
            result.* = accelerator.parse(text_ptr[0..text_len]) catch {
                return false;
            };
            return true;
        }

        fn filesDropped(handle: ?*core_module.Core, paths_ptr: [*]const u8, paths_len: usize) callconv(.c) bool {
            const core = handle orelse {
                @panic("ziggy_files_dropped called with a null handle");
            };
            core.filesDropped(paths_ptr[0..paths_len]) catch |err| {
                std.debug.print("ziggy_files_dropped failed: {s}\n", .{@errorName(err)});
                return false;
            };
            return true;
        }

        fn testHooksEnabled() callconv(.c) bool {
            return build_options.test_hooks;
        }
    };
    @export(&Api.create, .{ .name = "ziggy_create" });
    @export(&Api.destroy, .{ .name = "ziggy_destroy" });
    @export(&Api.postMessage, .{ .name = "ziggy_post_message" });
    @export(&Api.checkUrl, .{ .name = "ziggy_check_url" });
    @export(&Api.menuJson, .{ .name = "ziggy_menu_json" });
    @export(&Api.uiFile, .{ .name = "ziggy_ui_file" });
    @export(&Api.injectScript, .{ .name = "ziggy_inject_script" });
    @export(&Api.parseAccelerator, .{ .name = "ziggy_parse_accelerator" });
    @export(&Api.testHooksEnabled, .{ .name = "ziggy_test_hooks_enabled" });
    @export(&Api.filesDropped, .{ .name = "ziggy_files_dropped" });
}
