//
// The Ziggy example's core library. It exports Ziggy's C interface, serving the example's own handlers, and, for an
// Android target, the JNI entry points of Ziggy's Android shell.
//

const builtin = @import("builtin");
const ziggy = @import("ziggy-core");
const handlers = @import("handlers.zig");

//
// Zig's MachO stack trace symbolizer calls _dyld_get_image_header_containing_address, which the iOS SDK does not
// export, so on iOS it is switched off and a stack trace prints addresses only.
//
pub const debug = if (builtin.os.tag == .ios) struct {
    pub const SelfInfo = void;
} else struct {};

comptime {
    ziggy.ziggy_api.exportApi(handlers.app);
    if (builtin.abi.isAndroid()) {
        ziggy.jni.exportJni(handlers.app);
    }
}
