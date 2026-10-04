//
// The C interface to the core. An app calls exportApi with its own handlers and the functions below are exported
// from its library, so every shell reaches the core the same way. The declarations are in ziggy.h.
//

const std = @import("std");
const build_options = @import("build_options");
const types = @import("types.zig");
const core_module = @import("core.zig");
const accelerator = @import("accelerator.zig");

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

        fn parseAccelerator(text_ptr: [*]const u8, text_len: usize, result: *accelerator.Accelerator) callconv(.c) bool {
            result.* = accelerator.parse(text_ptr[0..text_len]) catch {
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
    @export(&Api.parseAccelerator, .{ .name = "ziggy_parse_accelerator" });
    @export(&Api.testHooksEnabled, .{ .name = "ziggy_test_hooks_enabled" });
}
