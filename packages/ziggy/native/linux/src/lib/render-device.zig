//
// Chooses the graphics card WebKitGTK draws with. WebKitGTK sets up a card through GBM and EGL, and when that setup fails it aborts
// the whole program rather than drawing without the card. A card whose driver is broken (a driver updated without a reboot, so the
// kernel and the libraries no longer match, is one way) then stops the app from starting at all. This tries the same setup on each
// card in a child process, which a broken driver may crash without harm, and tells WebKitGTK to use the first card it worked on.
//

const std = @import("std");
const c = @import("gtk.zig");

const GbmDevice = opaque {};

// EGL_PLATFORM_GBM_KHR, the platform eglGetPlatformDisplay is asked for when the display is a GBM device.
const EGL_PLATFORM_GBM_KHR: c_uint = 0x31D7;

extern fn gbm_create_device(fd: c_int) ?*GbmDevice;
extern fn eglGetPlatformDisplay(platform: c_uint, native_display: ?*anyopaque, attrib_list: ?[*]const isize) ?*anyopaque;
extern fn eglInitialize(display: *anyopaque, major: ?*i32, minor: ?*i32) c_uint;

//
// Sets WEBKIT_WEB_RENDER_DEVICE_FILE to the first card the setup works on, trying the card that started the display first and
// then the rest in the order the system lists them. When it works on none, WebKitGTK's GPU drawing is turned off with
// WEBKIT_DISABLE_DMABUF_RENDERER, so it draws without a card instead of aborting. A setting made in the environment is left
// alone. Must be called before the program starts any thread, because the check forks.
//
pub fn chooseRenderDevice() !void {
    if (c.g_getenv("WEBKIT_WEB_RENDER_DEVICE_FILE") != null or c.g_getenv("WEBKIT_DISABLE_DMABUF_RENDERER") != null) {
        return;
    }
    const directory = c.g_dir_open("/sys/class/drm", 0, null) orelse {
        return;
    };
    defer c.g_dir_close(directory);
    var boot_devices: std.ArrayList([*:0]u8) = .empty;
    defer boot_devices.deinit(std.heap.c_allocator);
    var other_devices: std.ArrayList([*:0]u8) = .empty;
    defer other_devices.deinit(std.heap.c_allocator);
    defer for (boot_devices.items) |path| c.g_free(path);
    defer for (other_devices.items) |path| c.g_free(path);
    while (c.g_dir_read_name(directory)) |entry| {
        const name = std.mem.span(entry);
        if (!std.mem.startsWith(u8, name, "renderD")) {
            continue;
        }
        const boot_vga_path = c.g_build_filename("/sys/class/drm", entry, "device", "boot_vga", @as([*c]const u8, null));
        defer c.g_free(boot_vga_path);
        var boot_vga: [*c]u8 = null;
        const is_boot = c.g_file_get_contents(boot_vga_path, &boot_vga, null, null) != 0 and boot_vga[0] == '1';
        c.g_free(boot_vga);
        const device_path = c.g_build_filename("/dev/dri", entry, @as([*c]const u8, null));
        try (if (is_boot) &boot_devices else &other_devices).append(std.heap.c_allocator, device_path);
    }
    for ([_][]const [*:0]u8{ boot_devices.items, other_devices.items }) |devices| {
        for (devices) |device_path| {
            if (try renderDeviceWorks(device_path)) {
                if (c.setenv("WEBKIT_WEB_RENDER_DEVICE_FILE", device_path, 1) != 0) {
                    return error.SetEnvironmentFailed;
                }
                return;
            }
            std.debug.print("ziggy shell: the graphics card {s} could not be set up, so the web view will not draw with it.\n", .{device_path});
        }
    }
    std.debug.print("ziggy shell: no graphics card could be set up, so the web view draws without one.\n", .{});
    if (c.setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", 1) != 0) {
        return error.SetEnvironmentFailed;
    }
}

//
// Whether WebKitGTK's setup works on a card: opens it, makes a GBM device of it and initialises an EGL display on that device,
// in a child process. A child that fails, crashes or is still going after ten seconds counts as the setup not working.
//
fn renderDeviceWorks(device_path: [*:0]const u8) !bool {
    const pid = std.c.fork();
    if (pid < 0) {
        return error.ForkFailed;
    }
    if (pid == 0) {
        _ = std.c.alarm(10);
        const fd = std.c.open(device_path, .{
            .ACCMODE = .RDWR,
            .CLOEXEC = true,
        });
        if (fd < 0) {
            std.c._exit(1);
        }
        const gbm_device = gbm_create_device(fd) orelse std.c._exit(1);
        const display = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm_device, null) orelse std.c._exit(1);
        std.c._exit(if (eglInitialize(display, null, null) != 0) 0 else 1);
    }
    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) != pid) {
        return error.WaitFailed;
    }
    const wait_status: u32 = @bitCast(status);
    return std.c.W.IFEXITED(wait_status) and std.c.W.EXITSTATUS(wait_status) == 0;
}
