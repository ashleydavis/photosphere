const std = @import("std");

//
// Zig ships no headers or libraries for iOS. The C code that includes Apple frameworks (the AWS SDK for C, aws-lc's CPU jitter entropy)
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
// Finds the SDK of an iOS target with `xcrun --sdk <sdk> --show-sdk-path`, or returns null when there is none: `xcrun` is not installed
// (any machine but a Mac with Xcode), it fails, or it prints no path. A sysroot the build was given (`--sysroot`) counts as found. Null
// for a target that is not iOS.
//
pub fn findSdkForIos(b: *std.Build, target: std.Build.ResolvedTarget) ?[]const u8 {
    if (target.result.os.tag != .ios) {
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
// Makes the build compile for an iOS target against Apple's SDK: gives the SDK found by findSdkForIos to every compile step as the
// sysroot (`--sysroot`), which is how Zig then finds the usr/include, the frameworks and the libraries of the SDK instead of its own
// headers. Does nothing for any other target: a native macOS build finds its SDK by itself. Stops the build with a message that names the
// SDK when there is none. `what` names the thing being built, for the message.
//
pub fn useSdkForIos(b: *std.Build, target: std.Build.ResolvedTarget, what: []const u8) !void {
    if (target.result.os.tag != .ios) {
        return;
    }
    b.sysroot = findSdkForIos(b, target) orelse {
        const name = sdkName(target.result.os.tag, target.result.abi).?;
        std.log.err("{s} for {s} needs Apple's {s} SDK, which comes with Xcode on a Mac and is found with `xcrun --sdk {s} --show-sdk-path`. It was not found here. Build for iOS on a Mac with Xcode installed.", .{ what, try target.result.zigTriple(b.allocator), name, name });
        std.process.exit(1);
    };
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
