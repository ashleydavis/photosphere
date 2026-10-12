//
// The JNI crossing for Ziggy's Android shell, written in Zig against the NDK's own jni.h. The Java class
// dev.ziggy.shell.ZiggyNative declares the native methods and the Java interface dev.ziggy.shell.ZiggyHost is what the
// core calls back into. An app calls exportJni with its own handlers, in a comptime block of its library's root file, and
// the Java_dev_ziggy_shell_ZiggyNative_* functions below are exported from that library.
//
// Everything the crossing needs lives in a Bridge, which is allocated by create and whose address is the jlong handle the
// Java side holds. The core's callbacks get the same address as their user_data. Nothing is kept in a global.
//
// Messages cross as byte arrays holding UTF-8, because the JNI string functions use a modified UTF-8 that is not valid
// UTF-8 for characters outside the basic multilingual plane. Configuration strings (paths) are plain text and
// use the JNI string functions.
//

const std = @import("std");
const build_options = @import("build_options");
const c = @import("jni-c");
const types = @import("types.zig");
const core_module = @import("core.zig");
const ui_files = @import("ui-files.zig");
const inject_script = @import("inject-script.zig");
const host_reply = @import("host-reply.zig");

//
// The Java interface the core calls back into.
//
const host_class_name = "dev/ziggy/shell/ZiggyHost";

//
// Everything one created core needs to reach back into Java. The address of a Bridge is the handle the Java side holds.
//
const Bridge = struct {
    // The Java virtual machine, used to attach a thread that is not a Java thread.
    java_vm: *c.JavaVM,
    // A global reference to the Java object that implements ZiggyHost.
    host: c.jobject,
    // ZiggyHost.onCoreMessage(byte[]).
    on_core_message_method: c.jmethodID,
    // ZiggyHost.osVersionJson().
    os_version_json_method: c.jmethodID,
    // ZiggyHost.quit().
    quit_method: c.jmethodID,
    // ZiggyHost.keepAlive(boolean).
    keep_alive_method: c.jmethodID,
    // ZiggyHost.pickPathsJson(int, String, String).
    pick_paths_method: c.jmethodID,
    // ZiggyHost.hostRequest(byte[], byte[]).
    host_request_method: c.jmethodID,
    // The core, once it has been created.
    core: *core_module.Core,
    // The owned copy of the test port file path, or null when there is none. The core keeps the pointer, so it lives as long as the core.
    test_port_file: ?[:0]u8,
};

//
// A JNI environment for the current thread, attached for the call if the thread was not already a Java thread.
//
const Attachment = struct {
    // The Java virtual machine.
    java_vm: *c.JavaVM,
    // The environment of the current thread.
    env: *c.JNIEnv,
    // Whether this attachment attached the thread and so has to detach it.
    attached_here: bool,
};

//
// The table of JNI functions behind an environment.
//
fn envTable(env: *c.JNIEnv) *const c.struct_JNINativeInterface {
    return env.*;
}

//
// The table of Java virtual machine functions behind a virtual machine pointer.
//
fn vmTable(java_vm: *c.JavaVM) *const c.struct_JNIInvokeInterface {
    return java_vm.*;
}

//
// Gives the current thread a JNI environment. A thread the core started is not a Java thread, so it is attached here and
// detached by detach, which keeps a thread that exits from ever holding an attachment the virtual machine would object to.
//
fn attach(java_vm: *c.JavaVM) Attachment {
    var env: ?*c.JNIEnv = null;
    const get_env_result = vmTable(java_vm).GetEnv.?(java_vm, @ptrCast(&env), c.JNI_VERSION_1_6);
    if (get_env_result == c.JNI_OK) {
        return .{
            .java_vm = java_vm,
            .env = env.?,
            .attached_here = false,
        };
    }
    if (get_env_result != c.JNI_EDETACHED) {
        @panic("Ziggy JNI: GetEnv failed");
    }
    if (vmTable(java_vm).AttachCurrentThread.?(java_vm, @ptrCast(&env), null) != c.JNI_OK) {
        @panic("Ziggy JNI: AttachCurrentThread failed");
    }
    return .{
        .java_vm = java_vm,
        .env = env.?,
        .attached_here = true,
    };
}

//
// Undoes attach: detaches the thread when attach was what attached it.
//
fn detach(attachment: Attachment) void {
    if (!attachment.attached_here) {
        return;
    }
    if (vmTable(attachment.java_vm).DetachCurrentThread.?(attachment.java_vm) != c.JNI_OK) {
        @panic("Ziggy JNI: DetachCurrentThread failed");
    }
}

//
// Ends the process with a message in the log. Used for a failure in a callback that has nowhere to report it to.
//
fn fatal(env: *c.JNIEnv, message: [*:0]const u8) noreturn {
    envTable(env).FatalError.?(env, message);
    @panic("Ziggy JNI: FatalError returned");
}

//
// When a Java exception is pending, prints it to the log and ends the process. Used after a call into Java from a callback.
//
fn failOnPendingException(env: *c.JNIEnv, message: [*:0]const u8) void {
    if (envTable(env).ExceptionCheck.?(env) == c.JNI_FALSE) {
        return;
    }
    envTable(env).ExceptionDescribe.?(env);
    envTable(env).ExceptionClear.?(env);
    fatal(env, message);
}

//
// Throws a Java exception of the given class with a message. The exception is delivered when the native method returns.
//
fn throwJava(env: *c.JNIEnv, class_name: [*:0]const u8, message: []const u8) void {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buffer, "{s}", .{message}) catch blk: {
        buffer[buffer.len - 1] = 0;
        break :blk buffer[0 .. buffer.len - 1 :0];
    };
    const class = envTable(env).FindClass.?(env, class_name);
    if (class == null) {
        // FindClass has already thrown NoClassDefFoundError, which is as loud as this one.
        return;
    }
    _ = envTable(env).ThrowNew.?(env, class, text.ptr);
}

//
// Copies a Java string into memory the Bridge owns. Returns null when the Java string is null.
//
fn dupeJavaString(env: *c.JNIEnv, allocator: std.mem.Allocator, string: c.jstring) !?[:0]u8 {
    if (string == null) {
        return null;
    }
    const chars = envTable(env).GetStringUTFChars.?(env, string, null);
    if (chars == null) {
        return error.JavaException;
    }
    defer envTable(env).ReleaseStringUTFChars.?(env, string, chars);
    return try allocator.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(chars))));
}

//
// Copies the bytes of a Java byte array into memory the caller frees. The bytes are copied rather than pinned, because
// handling a message can call back into Java, which a pinned array does not allow.
//
fn copyJavaBytes(env: *c.JNIEnv, allocator: std.mem.Allocator, array: c.jbyteArray) ![]u8 {
    const length: usize = @intCast(envTable(env).GetArrayLength.?(env, array));
    const copy = try allocator.alloc(u8, length);
    errdefer allocator.free(copy);
    envTable(env).GetByteArrayRegion.?(env, array, 0, @intCast(length), @ptrCast(copy.ptr));
    if (envTable(env).ExceptionCheck.?(env) == c.JNI_TRUE) {
        return error.JavaException;
    }
    return copy;
}

//
// The core's deliver callback. It runs on any thread: it hands the message to ZiggyHost.onCoreMessage as a new byte array,
// and the Java side moves it to the main thread.
//
fn deliverCallback(user_data: ?*anyopaque, message_ptr: [*]const u8, message_len: usize) callconv(.c) void {
    const bridge: *Bridge = @ptrCast(@alignCast(user_data.?));
    const attachment = attach(bridge.java_vm);
    defer detach(attachment);
    const env = attachment.env;
    const array = envTable(env).NewByteArray.?(env, @intCast(message_len));
    if (array == null) {
        failOnPendingException(env, "Ziggy JNI: could not allocate a byte array for a message");
        fatal(env, "Ziggy JNI: could not allocate a byte array for a message");
    }
    defer envTable(env).DeleteLocalRef.?(env, array);
    envTable(env).SetByteArrayRegion.?(env, array, 0, @intCast(message_len), @ptrCast(message_ptr));
    failOnPendingException(env, "Ziggy JNI: could not copy a message into a byte array");
    var arguments = [1]c.jvalue{
        .{
            .l = array,
        },
    };
    envTable(env).CallVoidMethodA.?(env, bridge.host, bridge.on_core_message_method, &arguments);
    failOnPendingException(env, "Ziggy JNI: ZiggyHost.onCoreMessage threw");
}

//
// The native host callback that answers the operating system's version, by asking ZiggyHost.osVersionJson for the JSON
// text. Returns the number of bytes written, or a negative number when Java cannot answer or the answer does not fit.
//
fn osVersionCallback(user_data: ?*anyopaque, buffer: [*]u8, capacity: usize) callconv(.c) isize {
    const bridge: *Bridge = @ptrCast(@alignCast(user_data.?));
    const attachment = attach(bridge.java_vm);
    defer detach(attachment);
    const env = attachment.env;
    const string = envTable(env).CallObjectMethodA.?(env, bridge.host, bridge.os_version_json_method, null);
    failOnPendingException(env, "Ziggy JNI: ZiggyHost.osVersionJson threw");
    if (string == null) {
        return -1;
    }
    defer envTable(env).DeleteLocalRef.?(env, string);
    const chars = envTable(env).GetStringUTFChars.?(env, @ptrCast(string), null);
    if (chars == null) {
        failOnPendingException(env, "Ziggy JNI: could not read the operating system version");
        return -1;
    }
    defer envTable(env).ReleaseStringUTFChars.?(env, @ptrCast(string), chars);
    const text = std.mem.span(@as([*:0]const u8, @ptrCast(chars)));
    if (text.len > capacity) {
        return -1;
    }
    @memcpy(buffer[0..text.len], text);
    return @intCast(text.len);
}

//
// The native host callback that quits the application, by calling ZiggyHost.quit. Called by the test control connection,
// from its own thread.
//
fn quitCallback(user_data: ?*anyopaque) callconv(.c) void {
    const bridge: *Bridge = @ptrCast(@alignCast(user_data.?));
    const attachment = attach(bridge.java_vm);
    defer detach(attachment);
    const env = attachment.env;
    envTable(env).CallVoidMethodA.?(env, bridge.host, bridge.quit_method, null);
    failOnPendingException(env, "Ziggy JNI: ZiggyHost.quit threw");
}

//
// What a signal that is only there to interrupt a blocked system call does when it arrives: nothing.
//
fn doNothingSignalHandler(signal_number: c_int) callconv(.c) void {
    _ = signal_number;
}

//
// WORKAROUND, with the reason and what it fixed.
//
// The problem: every task the core cancels while it is blocked in a system call (the test control connection's reads, the retry timer
// that openStorage cancels after a read finishes) is cancelled by sending its thread SIGIO, which returns the call early. That needs
// a do-nothing SIGIO handler, and Zig 0.16.0's threaded Io installs it when it is created with options (the test control connection's
// is). It builds the sigaction struct in the layout glibc uses, and Android's libc has the flags first, so the install lands as no
// handler at all, the default action is restored, and the first cancel of a blocked task ends the whole app with "I/O possible"
// (signal 29). Every Android scenario died this way: the app log stops mid-load and the harness times out waiting for a log line.
//
// What this does: installs the same do-nothing handler for SIGIO and SIGPIPE through the NDK's own struct sigaction and sigaction. It
// has to run after the core is created, because creating the core is what makes Zig overwrite the handler, and it checks by reading
// the handler back so a lost install is loud.
//
// TODO: investigate and remove. Check whether a later Zig fixes the struct layout for Android, and whether the threaded Io should be
// given a way to skip installing its own handler. The Zig threaded Io's deinit also restores the handler it replaced, which on Android
// is the default, so the handler is gone again once the test control connection stops.
//
fn installSignalHandlers() void {
    var action = std.mem.zeroes(c.struct_sigaction);
    action.unnamed_0.sa_handler = doNothingSignalHandler;
    if (c.sigaction(c.SIGIO, &action, null) != 0) {
        @panic("Ziggy JNI: could not install the SIGIO handler");
    }
    if (c.sigaction(c.SIGPIPE, &action, null) != 0) {
        @panic("Ziggy JNI: could not install the SIGPIPE handler");
    }
    var installed = std.mem.zeroes(c.struct_sigaction);
    if (c.sigaction(c.SIGIO, null, &installed) != 0) {
        @panic("Ziggy JNI: could not read the SIGIO handler back");
    }
    if (installed.unnamed_0.sa_handler != doNothingSignalHandler) {
        @panic("Ziggy JNI: the SIGIO handler was not the one installed");
    }
}

//
// The native host callback that does a menu action. A phone has no menu bar and none of the shell's own actions (reload, zoom,
// full screen, quit), so every action reaches the page as a menu-action message, the way an action of the page's own does on a
// desktop. The core calls it from the thread of the test control connection.
//
fn menuActionCallback(user_data: ?*anyopaque, action: [*:0]const u8) callconv(.c) void {
    const bridge: *Bridge = @ptrCast(@alignCast(user_data.?));
    const message = std.json.Stringify.valueAlloc(std.heap.smp_allocator, .{
        .channel = "menu-action",
        .data = .{
            .action = std.mem.span(action),
        },
    }, .{}) catch @panic("Ziggy JNI: out of memory building a menu-action message");
    defer std.heap.smp_allocator.free(message);
    bridge.core.postMessage(message);
}

//
// The native host callback that keeps the app running, or says it need not be, by calling ZiggyHost.keepAlive. The core calls it
// from the thread that queued or ended the task.
//
fn keepAliveCallback(user_data: ?*anyopaque, keep_running: bool) callconv(.c) void {
    const bridge: *Bridge = @ptrCast(@alignCast(user_data.?));
    const attachment = attach(bridge.java_vm);
    defer detach(attachment);
    const env = attachment.env;
    var arguments = [1]c.jvalue{
        .{
            .z = if (keep_running) c.JNI_TRUE else c.JNI_FALSE,
        },
    };
    envTable(env).CallVoidMethodA.?(env, bridge.host, bridge.keep_alive_method, &arguments);
    failOnPendingException(env, "Ziggy JNI: ZiggyHost.keepAlive threw");
}

//
// The native host callback that shows a file or folder picker, by calling ZiggyHost.pickPathsJson, which waits for the user.
// The core calls it from a worker thread, so waiting here holds up only that worker. The answer comes back as a byte
// array of UTF-8 JSON, which is copied into the buffer. Returns the number of bytes written, or a negative number when the
// picker could not be shown (Java returns null and has logged why) or the answer does not fit.
//
fn pickPathsCallback(user_data: ?*anyopaque, kind: i32, title: ?[*:0]const u8, initial_name: ?[*:0]const u8, buffer: [*]u8, capacity: usize) callconv(.c) isize {
    const bridge: *Bridge = @ptrCast(@alignCast(user_data.?));
    const attachment = attach(bridge.java_vm);
    defer detach(attachment);
    const env = attachment.env;
    var title_string: c.jstring = null;
    if (title) |text| {
        title_string = envTable(env).NewStringUTF.?(env, text);
        if (title_string == null) {
            failOnPendingException(env, "Ziggy JNI: could not make the picker title");
            return -1;
        }
    }
    defer if (title_string != null) {
        envTable(env).DeleteLocalRef.?(env, title_string);
    };
    var initial_name_string: c.jstring = null;
    if (initial_name) |text| {
        initial_name_string = envTable(env).NewStringUTF.?(env, text);
        if (initial_name_string == null) {
            failOnPendingException(env, "Ziggy JNI: could not make the picker file name");
            return -1;
        }
    }
    defer if (initial_name_string != null) {
        envTable(env).DeleteLocalRef.?(env, initial_name_string);
    };
    var arguments = [3]c.jvalue{
        .{
            .i = kind,
        },
        .{
            .l = title_string,
        },
        .{
            .l = initial_name_string,
        },
    };
    const answer = envTable(env).CallObjectMethodA.?(env, bridge.host, bridge.pick_paths_method, &arguments);
    failOnPendingException(env, "Ziggy JNI: ZiggyHost.pickPathsJson threw");
    if (answer == null) {
        return -1;
    }
    defer envTable(env).DeleteLocalRef.?(env, answer);
    const length: usize = @intCast(envTable(env).GetArrayLength.?(env, @ptrCast(answer)));
    if (length > capacity) {
        return -1;
    }
    envTable(env).GetByteArrayRegion.?(env, @ptrCast(answer), 0, @intCast(length), @ptrCast(buffer));
    failOnPendingException(env, "Ziggy JNI: could not copy the picker answer");
    return @intCast(length);
}

//
// Makes a Java byte array holding a copy of the bytes, or null with an exception pending when it could not be made.
//
fn newJavaBytes(env: *c.JNIEnv, bytes: []const u8) c.jbyteArray {
    const array = envTable(env).NewByteArray.?(env, @intCast(bytes.len));
    if (array == null) {
        return null;
    }
    envTable(env).SetByteArrayRegion.?(env, array, 0, @intCast(bytes.len), @ptrCast(bytes.ptr));
    if (envTable(env).ExceptionCheck.?(env) == c.JNI_TRUE) {
        envTable(env).DeleteLocalRef.?(env, array);
        return null;
    }
    return array;
}

//
// The native host callback that does one thing only the app's own code can do, by calling ZiggyHost.hostRequest, which may wait for
// the user. The core calls it from a worker thread with no lock held. The method and the request cross as UTF-8 bytes, and Java answers
// with a status byte (1 when it did what was asked, 0 when it could not) followed by the answer or the reason. Every way the call can
// fail is returned as a failure with a reason, so the core reports it to the page.
//
fn hostRequestCallback(user_data: ?*anyopaque, method: [*:0]const u8, request_json: [*:0]const u8, buffer: [*]u8, capacity: usize) callconv(.c) isize {
    const bridge: *Bridge = @ptrCast(@alignCast(user_data.?));
    const method_name = std.mem.span(method);
    const attachment = attach(bridge.java_vm);
    defer detach(attachment);
    const env = attachment.env;
    const method_array = newJavaBytes(env, method_name);
    if (method_array == null) {
        failOnPendingException(env, "Ziggy JNI: could not make the host request method");
        return host_reply.writeHostReply(false, method_name, "The host request could not be sent to the app.", buffer, capacity);
    }
    defer envTable(env).DeleteLocalRef.?(env, method_array);
    const request_array = newJavaBytes(env, std.mem.span(request_json));
    if (request_array == null) {
        failOnPendingException(env, "Ziggy JNI: could not make the host request argument");
        return host_reply.writeHostReply(false, method_name, "The host request could not be sent to the app.", buffer, capacity);
    }
    defer envTable(env).DeleteLocalRef.?(env, request_array);
    var arguments = [2]c.jvalue{
        .{
            .l = method_array,
        },
        .{
            .l = request_array,
        },
    };
    const answer = envTable(env).CallObjectMethodA.?(env, bridge.host, bridge.host_request_method, &arguments);
    failOnPendingException(env, "Ziggy JNI: ZiggyHost.hostRequest threw");
    if (answer == null) {
        return host_reply.writeHostReply(false, method_name, "The app gave no answer to the host request.", buffer, capacity);
    }
    defer envTable(env).DeleteLocalRef.?(env, answer);
    const length: usize = @intCast(envTable(env).GetArrayLength.?(env, @ptrCast(answer)));
    if (length < 1) {
        return host_reply.writeHostReply(false, method_name, "The app's answer to the host request was empty.", buffer, capacity);
    }
    const text = std.heap.smp_allocator.alloc(u8, length) catch {
        return host_reply.writeHostReply(false, method_name, "The core ran out of memory reading the app's answer to a host request.", buffer, capacity);
    };
    defer std.heap.smp_allocator.free(text);
    envTable(env).GetByteArrayRegion.?(env, @ptrCast(answer), 0, @intCast(length), @ptrCast(text.ptr));
    failOnPendingException(env, "Ziggy JNI: could not copy the answer to a host request");
    return host_reply.writeHostReply(text[0] == 1, method_name, text[1..], buffer, capacity);
}

//
// What createBridge needs from Java.
//
const CreateArguments = struct {
    // The Java object that implements ZiggyHost.
    host: c.jobject,
    // The number of worker threads.
    worker_threads: u32,
    // The limit on child tasks in flight for any one parent task.
    max_concurrent_child_tasks: u32,
    // The URL prefix of the app's bundled page.
    app_url_prefix: c.jstring,
    // The app's private data directory.
    data_dir: c.jstring,
    // Whether to start the test control connection.
    test_mode: c.jboolean,
    // The test control port file, or null.
    test_port_file: c.jstring,
};

//
// Creates the Bridge and the core behind it. On failure it returns an error, and a Java exception is already pending
// when the error is error.JavaException.
//
fn createBridge(env: *c.JNIEnv, allocator: std.mem.Allocator, arguments: CreateArguments, app: core_module.AppHandlers) !*Bridge {
    const bridge = try allocator.create(Bridge);
    errdefer allocator.destroy(bridge);

    var java_vm: ?*c.JavaVM = null;
    if (envTable(env).GetJavaVM.?(env, @ptrCast(&java_vm)) != c.JNI_OK) {
        return error.GetJavaVmFailed;
    }
    bridge.java_vm = java_vm.?;

    const host_class = envTable(env).FindClass.?(env, host_class_name);
    if (host_class == null) {
        return error.JavaException;
    }
    defer envTable(env).DeleteLocalRef.?(env, host_class);
    bridge.on_core_message_method = envTable(env).GetMethodID.?(env, host_class, "onCoreMessage", "([B)V") orelse {
        return error.JavaException;
    };
    bridge.os_version_json_method = envTable(env).GetMethodID.?(env, host_class, "osVersionJson", "()Ljava/lang/String;") orelse {
        return error.JavaException;
    };
    bridge.quit_method = envTable(env).GetMethodID.?(env, host_class, "quit", "()V") orelse {
        return error.JavaException;
    };
    bridge.keep_alive_method = envTable(env).GetMethodID.?(env, host_class, "keepAlive", "(Z)V") orelse {
        return error.JavaException;
    };
    bridge.pick_paths_method = envTable(env).GetMethodID.?(env, host_class, "pickPathsJson", "(ILjava/lang/String;Ljava/lang/String;)[B") orelse {
        return error.JavaException;
    };

    bridge.host_request_method = envTable(env).GetMethodID.?(env, host_class, "hostRequest", "([B[B)[B") orelse {
        return error.JavaException;
    };

    bridge.host = envTable(env).NewGlobalRef.?(env, arguments.host);
    if (bridge.host == null) {
        return error.JavaException;
    }
    errdefer envTable(env).DeleteGlobalRef.?(env, bridge.host);

    const app_url_prefix = (try dupeJavaString(env, allocator, arguments.app_url_prefix)) orelse {
        return error.AppUrlPrefixMissing;
    };
    defer allocator.free(app_url_prefix);
    const data_dir = (try dupeJavaString(env, allocator, arguments.data_dir)) orelse {
        return error.DataDirMissing;
    };
    defer allocator.free(data_dir);
    bridge.test_port_file = try dupeJavaString(env, allocator, arguments.test_port_file);
    errdefer if (bridge.test_port_file) |port_file| {
        allocator.free(port_file);
    };

    const config = types.ZiggyConfig{
        .user_data = bridge,
        .deliver = deliverCallback,
        .os_version = osVersionCallback,
        .quit = quitCallback,
        .pick_paths = pickPathsCallback,
        .menu_action = menuActionCallback,
        .keep_alive = keepAliveCallback,
        .worker_threads = arguments.worker_threads,
        .max_concurrent_child_tasks = arguments.max_concurrent_child_tasks,
        .app_url_prefix = app_url_prefix.ptr,
        .data_dir = data_dir.ptr,
        .test_mode = arguments.test_mode != c.JNI_FALSE,
        .test_port_file = if (bridge.test_port_file) |port_file| port_file.ptr else null,
        .host_request = hostRequestCallback,
        // A phone's screenshot is taken from the host with adb, so the app has no way of taking one itself.
        .screenshot = null,
    };
    bridge.core = try core_module.Core.create(allocator, config, app);
    installSignalHandlers();
    return bridge;
}

//
// Exports the JNI entry points of dev.ziggy.shell.ZiggyNative and JNI_OnLoad from the library that calls this, serving the
// given app handlers. It is called once, in a comptime block of the app's root file, and only for an Android target.
//
pub fn exportJni(comptime app: core_module.AppHandlers) void {
    const Exports = struct {
        //
        // Called when the virtual machine loads the library: checks that it supports the JNI version the entry points use.
        //
        fn onLoad(java_vm: *c.JavaVM, reserved: ?*anyopaque) callconv(.c) c.jint {
            _ = reserved;
            var env: ?*c.JNIEnv = null;
            if (vmTable(java_vm).GetEnv.?(java_vm, @ptrCast(&env), c.JNI_VERSION_1_6) != c.JNI_OK) {
                @panic("Ziggy JNI: the virtual machine does not support JNI 1.6");
            }
            return c.JNI_VERSION_1_6;
        }

        //
        // Says whether this library was built with the test hooks.
        //
        fn testHooksEnabled(env: *c.JNIEnv, class: c.jclass) callconv(.c) c.jboolean {
            _ = env;
            _ = class;
            return if (build_options.test_hooks) c.JNI_TRUE else c.JNI_FALSE;
        }

        //
        // Creates the core for the app's host object and returns its handle, or zero with a Java exception pending.
        //
        fn create(
            env: *c.JNIEnv,
            class: c.jclass,
            host: c.jobject,
            worker_threads: c.jint,
            max_concurrent_child_tasks: c.jint,
            app_url_prefix: c.jstring,
            data_dir: c.jstring,
            test_mode: c.jboolean,
            test_port_file: c.jstring,
        ) callconv(.c) c.jlong {
            _ = class;
            const bridge = createBridge(env, std.heap.smp_allocator, .{
                .host = host,
                .worker_threads = @intCast(worker_threads),
                .max_concurrent_child_tasks = @intCast(max_concurrent_child_tasks),
                .app_url_prefix = app_url_prefix,
                .data_dir = data_dir,
                .test_mode = test_mode,
                .test_port_file = test_port_file,
            }, app) catch |err| {
                if (err != error.JavaException) {
                    var buffer: [128]u8 = undefined;
                    const message = std.fmt.bufPrint(&buffer, "Ziggy could not create the core: {s}", .{@errorName(err)}) catch "Ziggy could not create the core";
                    throwJava(env, "java/lang/IllegalStateException", message);
                }
                return 0;
            };
            return @intCast(@intFromPtr(bridge));
        }

        //
        // Destroys the core of the handle and releases everything the bridge held.
        //
        fn destroy(env: *c.JNIEnv, class: c.jclass, handle: c.jlong) callconv(.c) void {
            _ = class;
            const bridge: *Bridge = @ptrFromInt(@as(usize, @intCast(handle)));
            // After this returns nothing runs and nothing is delivered, so the Bridge can be released.
            bridge.core.destroy();
            envTable(env).DeleteGlobalRef.?(env, bridge.host);
            if (bridge.test_port_file) |port_file| {
                std.heap.smp_allocator.free(port_file);
            }
            std.heap.smp_allocator.destroy(bridge);
        }

        //
        // Passes a message from the page to the core.
        //
        fn postMessage(env: *c.JNIEnv, class: c.jclass, handle: c.jlong, message: c.jbyteArray) callconv(.c) void {
            _ = class;
            const bridge: *Bridge = @ptrFromInt(@as(usize, @intCast(handle)));
            const copy = copyJavaBytes(env, std.heap.smp_allocator, message) catch |err| {
                if (err != error.JavaException) {
                    throwJava(env, "java/lang/OutOfMemoryError", "Ziggy could not copy a message from the page");
                }
                return;
            };
            defer std.heap.smp_allocator.free(copy);
            bridge.core.postMessage(copy);
        }

        //
        // Asks the core what to do with an address the web view is about to load.
        //
        fn checkUrl(env: *c.JNIEnv, class: c.jclass, handle: c.jlong, url: c.jbyteArray) callconv(.c) c.jint {
            _ = class;
            const bridge: *Bridge = @ptrFromInt(@as(usize, @intCast(handle)));
            const copy = copyJavaBytes(env, std.heap.smp_allocator, url) catch |err| {
                if (err != error.JavaException) {
                    throwJava(env, "java/lang/OutOfMemoryError", "Ziggy could not copy an address to check");
                }
                return @intFromEnum(types.UrlDecision.block);
            };
            defer std.heap.smp_allocator.free(copy);
            return @intFromEnum(bridge.core.checkUrl(copy));
        }

        //
        // Copies the Java byte array of a request path and finds the bundled page's file for it. Null when there is no such
        // file, or when the path could not be copied (in which case a Java exception is pending).
        //
        fn findUiFile(env: *c.JNIEnv, handle: c.jlong, path: c.jbyteArray) ?*const ui_files.UiFile {
            const bridge: *Bridge = @ptrFromInt(@as(usize, @intCast(handle)));
            const copy = copyJavaBytes(env, std.heap.smp_allocator, path) catch |err| {
                if (err != error.JavaException) {
                    throwJava(env, "java/lang/OutOfMemoryError", "Ziggy could not copy a page path");
                }
                return null;
            };
            defer std.heap.smp_allocator.free(copy);
            return bridge.core.uiFile(copy);
        }

        //
        // Gives the script to inject into the page before it loads, as UTF-8 bytes.
        //
        fn injectScript(env: *c.JNIEnv, class: c.jclass) callconv(.c) c.jbyteArray {
            _ = class;
            const array = envTable(env).NewByteArray.?(env, @intCast(inject_script.text.len));
            if (array == null) {
                failOnPendingException(env, "Ziggy JNI: could not allocate a byte array for the inject script");
                fatal(env, "Ziggy JNI: could not allocate a byte array for the inject script");
            }
            envTable(env).SetByteArrayRegion.?(env, array, 0, @intCast(inject_script.text.len), @ptrCast(inject_script.text.ptr));
            failOnPendingException(env, "Ziggy JNI: could not copy the inject script into a byte array");
            return array;
        }

        //
        // The query of the page's address as UTF-8 bytes, or null, with a Java exception pending, when the app could not make it.
        //
        fn pageQuery(env: *c.JNIEnv, class: c.jclass, handle: c.jlong) callconv(.c) c.jbyteArray {
            _ = class;
            const bridge: *Bridge = @ptrFromInt(@as(usize, @intCast(handle)));
            const text = bridge.core.pageQuery() catch |err| {
                throwJava(env, "java/lang/IllegalStateException", @errorName(err));
                return null;
            };
            const array = envTable(env).NewByteArray.?(env, @intCast(text.len));
            if (array == null) {
                failOnPendingException(env, "Ziggy JNI: could not allocate a byte array for the page query");
                fatal(env, "Ziggy JNI: could not allocate a byte array for the page query");
            }
            envTable(env).SetByteArrayRegion.?(env, array, 0, @intCast(text.len), @ptrCast(text.ptr));
            failOnPendingException(env, "Ziggy JNI: could not copy the page query into a byte array");
            return array;
        }

        //
        // Gives the bytes of a file of the bundled page, or null when the page has no such file.
        //
        fn uiFileContent(env: *c.JNIEnv, class: c.jclass, handle: c.jlong, path: c.jbyteArray) callconv(.c) c.jbyteArray {
            _ = class;
            const file = findUiFile(env, handle, path) orelse {
                return null;
            };
            const array = envTable(env).NewByteArray.?(env, @intCast(file.content.len));
            if (array == null) {
                failOnPendingException(env, "Ziggy JNI: could not allocate a byte array for a page file");
                fatal(env, "Ziggy JNI: could not allocate a byte array for a page file");
            }
            envTable(env).SetByteArrayRegion.?(env, array, 0, @intCast(file.content.len), @ptrCast(file.content.ptr));
            failOnPendingException(env, "Ziggy JNI: could not copy a page file into a byte array");
            return array;
        }

        //
        // Gives the content type of a file of the bundled page, or null when the page has no such file.
        //
        fn uiFileContentType(env: *c.JNIEnv, class: c.jclass, handle: c.jlong, path: c.jbyteArray) callconv(.c) c.jstring {
            _ = class;
            const file = findUiFile(env, handle, path) orelse {
                return null;
            };
            const text = envTable(env).NewStringUTF.?(env, ui_files.contentType(file.path).ptr);
            if (text == null) {
                failOnPendingException(env, "Ziggy JNI: could not allocate a string for a content type");
                fatal(env, "Ziggy JNI: could not allocate a string for a content type");
            }
            return text;
        }
    };
    @export(&Exports.onLoad, .{
        .name = "JNI_OnLoad",
    });
    @export(&Exports.testHooksEnabled, .{
        .name = "Java_dev_ziggy_shell_ZiggyNative_testHooksEnabled",
    });
    @export(&Exports.create, .{
        .name = "Java_dev_ziggy_shell_ZiggyNative_create",
    });
    @export(&Exports.destroy, .{
        .name = "Java_dev_ziggy_shell_ZiggyNative_destroy",
    });
    @export(&Exports.postMessage, .{
        .name = "Java_dev_ziggy_shell_ZiggyNative_postMessage",
    });
    @export(&Exports.checkUrl, .{
        .name = "Java_dev_ziggy_shell_ZiggyNative_checkUrl",
    });
    @export(&Exports.injectScript, .{
        .name = "Java_dev_ziggy_shell_ZiggyNative_injectScript",
    });
    @export(&Exports.pageQuery, .{
        .name = "Java_dev_ziggy_shell_ZiggyNative_pageQuery",
    });
    @export(&Exports.uiFileContent, .{
        .name = "Java_dev_ziggy_shell_ZiggyNative_uiFileContent",
    });
    @export(&Exports.uiFileContentType, .{
        .name = "Java_dev_ziggy_shell_ZiggyNative_uiFileContentType",
    });
}
