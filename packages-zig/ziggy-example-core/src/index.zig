//
// The Ziggy example's core library. It exports Ziggy's C interface, serving the example's own handlers, and, for an
// Android target, the JNI entry points of Ziggy's Android shell.
//

const builtin = @import("builtin");
const ziggy = @import("ziggy-core");
const handlers = @import("handlers.zig");

comptime {
    ziggy.ziggy_api.exportApi(handlers.app);
    if (builtin.abi.isAndroid()) {
        ziggy.jni.exportJni(handlers.app);
    }
}
