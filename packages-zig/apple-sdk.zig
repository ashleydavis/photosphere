const std = @import("std");

//
// Zig ships no headers or libraries for iOS, and uses the macOS SDK only for a native build (a target whose operating system and ABI are not
// given, see std/zig/system/darwin.zig): not for one that names a minimum version, such as the Photosphere App's macOS core, which is
// built for the macOS 11.0 its Xcode project targets. The C code that includes Apple frameworks (the AWS SDK for C, aws-lc's CPU jitter entropy)
// compiles against Apple's SDK, which comes with Xcode and is found with `xcrun --sdk <sdk> --show-sdk-path`: the same call Zig makes
// for a native macOS build (std/zig/system/darwin.zig), and the one the scripts that make ImageMagick's and FFmpeg's files for iOS make
// (packages-zig/media-tools-zig/*/generate-config.sh).
//

//
// Returns the name `xcrun --sdk` knows the SDK of an Apple operating system by, or null for an operating system that is not an Apple one
// this build covers. A simulator ABI has an SDK of its own.
//
pub fn sdkName(os: std.Target.Os.Tag, abi: std.Target.Abi) ?[]const u8 {
    switch (os) {
        .macos => {
            return "macosx";
        },
        .ios => {
            if (abi == .simulator) {
                return "iphonesimulator";
            }
            return "iphoneos";
        },
        else => {
            return null;
        },
    }
}

//
// True for a target whose C code needs Apple's SDK given to the build: every iOS target, and a macOS target that is not the native one.
//
pub fn needsSdk(query: std.Target.Query, result: std.Target) bool {
    if (result.os.tag == .ios) {
        return true;
    }
    return result.os.tag == .macos and !(query.isNativeOs() and query.isNativeAbi());
}

//
// Finds the SDK of a target that needs one (see needsSdk) with `xcrun --sdk <sdk> --show-sdk-path`, or returns null when there is none: `xcrun` is not installed
// (any machine but a Mac with Xcode), it fails, or it prints no path. A sysroot the build was given (`--sysroot`) counts as found. Null
// for a target that does not need one.
//
pub fn findSdk(b: *std.Build, target: std.Build.ResolvedTarget) ?[]const u8 {
    if (!needsSdk(target.query, target.result)) {
        return null;
    }
    if (b.sysroot) |sysroot| {
        return sysroot;
    }
    const name = sdkName(target.result.os.tag, target.result.abi).?;
    var exit_code: u8 = undefined;
    const output = b.runAllowFail(&.{ "xcrun", "--sdk", name, "--show-sdk-path" }, &exit_code, .ignore) catch {
        return null;
    };
    const path = std.mem.trimEnd(u8, output, "\r\n");
    if (path.len == 0) {
        return null;
    }
    return path;
}

//
// Returns the text of a libc file (see `zig libc`) that names the C library of an Apple SDK: its usr/include for the headers and its usr/lib
// for libSystem. Zig ships no C library for iOS, and given only the SDK as the sysroot it finds neither, so a build for a target that
// needs the SDK is given this file too.
//
pub fn libcFileText(allocator: std.mem.Allocator, sdk_path: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{
        "include_dir=", sdk_path, "/usr/include\n",
        "sys_include_dir=", sdk_path, "/usr/include\n",
        "crt_dir=", sdk_path, "/usr/lib\n",
        "msvc_lib_dir=\n",
        "kernel32_lib_dir=\n",
        "gcc_dir=\n",
    });
}
//
// Makes the build compile for a target that needs Apple's SDK (see needsSdk) against it: gives the build the SDK's C library as its libc file
// (see libcFileText), which is how Zig then finds the SDK's usr/include and libSystem instead of its own headers, unless the build was given
// a libc file. The SDK is not made the build's sysroot, because Zig gives the sysroot to every compile step, the programs the build runs on
// its own machine among them, and they then look for that machine's libSystem in the SDK. The frameworks are given to each library that
// needs them (see addSdkFrameworks). Does nothing for any other target: a native macOS build finds its SDK by itself. Stops the build with
// a message that names the SDK when there is none. `what` names the thing being built, for the message.
//
pub fn useSdk(b: *std.Build, target: std.Build.ResolvedTarget, what: []const u8) !void {
    if (!needsSdk(target.query, target.result)) {
        return;
    }
    const sdk_path = findSdk(b, target) orelse {
        const name = sdkName(target.result.os.tag, target.result.abi).?;
        std.log.err("{s} for {s} needs Apple's {s} SDK, which comes with Xcode on a Mac and is found with `xcrun --sdk {s} --show-sdk-path`. It was not found here. Build on a Mac with Xcode installed.", .{ what, try target.result.zigTriple(b.allocator), name, name });
        std.process.exit(1);
    };
    if (b.libc_file == null) {
        const file_name = b.fmt("{s}-libc.txt", .{sdkName(target.result.os.tag, target.result.abi).?});
        try b.cache_root.handle.writeFile(b.graph.io, .{
            .sub_path = file_name,
            .data = try libcFileText(b.allocator, sdk_path),
        });
        b.libc_file = try b.cache_root.join(b.allocator, &.{file_name});
    }
}
//
// Gives a module the frameworks of the SDK found by findSdk (its System/Library/Frameworks), for a target that needs the
// SDK. Zig finds no frameworks for such a target by itself, and a library that links one (CoreFoundation, Security, Network), or links a
// library that does, fails with "unable
// to find framework" without it. Does nothing for any other target: a native macOS build finds the frameworks by itself.
//
pub fn addSdkFrameworks(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (!needsSdk(target.query, target.result)) {
        return;
    }
    const sdk_path = findSdk(b, target) orelse {
        return;
    };
    module.addSystemFrameworkPath(.{
        .cwd_relative = b.pathJoin(&.{ sdk_path, "System", "Library", "Frameworks" }),
    });
}


test "sdkName gives the SDK of each Apple operating system" {
    try std.testing.expectEqualStrings("macosx", sdkName(.macos, .none).?);
    try std.testing.expectEqualStrings("iphoneos", sdkName(.ios, .none).?);
    try std.testing.expectEqualStrings("iphonesimulator", sdkName(.ios, .simulator).?);
}

test "sdkName gives nothing for an operating system that is not an Apple one" {
    try std.testing.expect(sdkName(.linux, .gnu) == null);
    try std.testing.expect(sdkName(.windows, .gnu) == null);
}

test "needsSdk is true for every iOS target and a macOS target that is not the native one" {
    for ([_][]const u8{ "aarch64-ios", "aarch64-ios-simulator", "x86_64-ios-simulator", "aarch64-macos.11.0", "x86_64-macos" }) |name| {
        const query = try std.Target.Query.parse(.{
            .arch_os_abi = name,
        });
        const result = try std.zig.system.resolveTargetQuery(std.testing.io, query);
        try std.testing.expect(needsSdk(query, result));
    }
}

test "needsSdk is false for the native target and any target that is not an Apple one" {
    const native_query: std.Target.Query = .{};
    try std.testing.expect(!needsSdk(native_query, try std.zig.system.resolveTargetQuery(std.testing.io, native_query)));
    for ([_][]const u8{ "x86_64-linux-gnu", "x86_64-windows-msvc", "aarch64-linux-android" }) |name| {
        const query = try std.Target.Query.parse(.{
            .arch_os_abi = name,
        });
        const result = try std.zig.system.resolveTargetQuery(std.testing.io, query);
        try std.testing.expect(!needsSdk(query, result));
    }
}

test "libcFileText names the SDK's headers and libraries" {
    const text = try libcFileText(std.testing.allocator, "/sdk");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("include_dir=/sdk/usr/include\nsys_include_dir=/sdk/usr/include\ncrt_dir=/sdk/usr/lib\nmsvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=\n", text);
}
