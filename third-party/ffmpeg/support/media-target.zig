const std = @import("std");

//
// The targets FFmpeg is built for, and how its generated files for each are named (config/<name>). They are the same as ImageMagick's,
// whose build has the same functions, so that both libraries are built for the same targets.
//

//
// The glibc version the libraries are compiled against on Linux with glibc, which is the version generate-config.sh (of ImageMagick
// and of FFmpeg) gives the compiler. The generated headers are answers about the C library headers of that version, and a target
// that is the machine itself would be compiled against whatever glibc the machine has, so the libraries are compiled for this
// version on any machine. The code runs where glibc is the same or newer.
//
pub const glibc_version: std.SemanticVersion = .{
    .major = 2,
    .minor = 35,
    .patch = 0,
};

//
// The target the libraries are compiled for: the target, with glibc's version set to glibc_version when it is Linux with glibc.
//
pub fn libraryTarget(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.ResolvedTarget {
    if (target.result.os.tag != .linux or !target.result.abi.isGnu()) {
        return target;
    }
    return b.resolveTargetQuery(.{
        .cpu_arch = target.result.cpu.arch,
        .os_tag = .linux,
        .abi = target.result.abi,
        .glibc_version = glibc_version,
    });
}

//
// The name of the directory of the generated headers for the target, which is the target's name as Zig spells it: for example
// "x86_64-linux-gnu", "aarch64-linux-android", "x86_64-windows-gnu", "x86_64-windows-msvc", "aarch64-macos" or "aarch64-ios-simulator". Fails for a
// target FFmpeg is not built for.
//
pub fn configName(b: *std.Build, target: std.Build.ResolvedTarget) ![]const u8 {
    const result = target.result;
    const arch = @tagName(result.cpu.arch);
    switch (result.os.tag) {
        .linux => {
            if (result.abi.isAndroid()) {
                return b.fmt("{s}-linux-android", .{arch});
            }
            if (result.abi.isGnu()) {
                return b.fmt("{s}-linux-gnu", .{arch});
            }
        },
        .windows => {
            if (result.abi == .gnu) {
                return b.fmt("{s}-windows-gnu", .{arch});
            }
            // The Photosphere App's Windows shell links WebView2's static loader, which is built for the MSVC ABI, so the app and
            // every library in it are built for that ABI.
            if (result.abi == .msvc) {
                return b.fmt("{s}-windows-msvc", .{arch});
            }
        },
        .macos => {
            return b.fmt("{s}-macos", .{arch});
        },
        .ios => {
            if (result.abi == .simulator) {
                return b.fmt("{s}-ios-simulator", .{arch});
            }
            return b.fmt("{s}-ios", .{arch});
        },
        else => {},
    }
    std.log.err("FFmpeg is not built for {s}-{s}-{s}.", .{ arch, @tagName(result.os.tag), @tagName(result.abi) });
    return error.UnsupportedTarget;
}

//
// Why zlib-ng, the zlib the program has one copy of, cannot be built for the target, or null when it can. Its build covers Linux (and
// Android), Windows, macOS and iOS, on x86_64 and aarch64.
//
pub fn zlibUnsupportedReason(b: *std.Build, target: std.Build.ResolvedTarget) ?[]const u8 {
    const os = target.result.os.tag;
    const arch = target.result.cpu.arch;
    // Zig ships no headers or libraries for iOS. On a Mac it finds the SDK of Xcode by itself, as the core library's own iOS build relies
    // on; anywhere else there is none to find.
    if (os == .ios and b.graph.host.result.os.tag != .macos) {
        return "Building for iOS needs Apple's iOS SDK, which comes with Xcode and only a Mac has. Build this on a Mac with Xcode installed.";
    }
    if (os != .linux and os != .windows and os != .macos and os != .ios) {
        return b.fmt("zlib-ng's build covers Linux, Android, Windows, macOS and iOS, not {s}.", .{@tagName(os)});
    }
    if (arch != .x86_64 and arch != .aarch64) {
        return b.fmt("zlib-ng's build covers x86_64 and aarch64, not {s}.", .{@tagName(arch)});
    }
    return null;
}

