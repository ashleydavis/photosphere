const std = @import("std");
const aws_c_common = @import("aws-c-common.zig");
const aws_checksums = @import("aws-checksums.zig");
const aws_c_cal = @import("aws-c-cal.zig");
const aws_c_io = @import("aws-c-io.zig");
const aws_c_compression = @import("aws-c-compression.zig");
const aws_c_http = @import("aws-c-http.zig");
const aws_c_sdkutils = @import("aws-c-sdkutils.zig");
const aws_c_auth = @import("aws-c-auth.zig");
const aws_c_s3 = @import("aws-c-s3.zig");
const aws_lc = @import("aws-lc.zig");
const s2n_tls = @import("s2n-tls.zig");

//
// Builds the AWS SDK for C (aws-c-s3 and the libraries under it) from the unmodified upstream sources fetched as the
// dependencies in build.zig.zon, and links it into a module. Each library has its own file in this directory that
// mirrors that library's CMakeLists.txt: the same source files, include paths, defines and generated config headers
// the CMake build uses for the target. See docs/aws-sdk.md for the versions and how to upgrade them.
//

//
// What every library's build needs to know: the target and what its CMake configure step would have found for it.
//
pub const Context = struct {
    // The build.
    b: *std.Build,

    // The target.
    target: std.Build.ResolvedTarget,

    // The optimization mode of the libraries: always ReleaseFast, the equivalent of the CMake Release build the SDK is
    // documented with (-O3 -DNDEBUG, no sanitizers), whatever mode the Zig code is built in.
    optimize: std.builtin.OptimizeMode,

    // True for Linux (CMake: `CMAKE_SYSTEM_NAME STREQUAL "Linux"`).
    isLinux: bool,

    // True for Windows (CMake: `WIN32`, and `MINGW`, since Zig targets Windows with the MinGW-w64 ABI).
    isWindows: bool,

    // True for macOS (CMake: `APPLE`, with `CMAKE_SYSTEM_NAME STREQUAL "Darwin"`).
    isMacos: bool,

    // True for x86_64 (CMake: `AWS_ARCH_INTEL` and `AWS_ARCH_INTEL_X64`).
    isX86_64: bool,

    // True for aarch64 (CMake: `AWS_ARCH_ARM64`).
    isAarch64: bool,

    // True when the target is not the machine running the build (CMake: `CMAKE_CROSSCOMPILING`).
    isCrossCompiling: bool,

    // True for Linux with musl as its C library (the Zig default for a Linux target that is not the host), false for
    // glibc and for the other operating systems. Some probes of the CMake files find different things in the two.
    isMusl: bool,

    //
    // Creates a static library module for the target that links libc (every SDK library is C).
    //
    pub fn createLibrary(self: *const Context, name: []const u8) *std.Build.Step.Compile {
        return self.createLibraryForTarget(name, self.target);
    }

    //
    // Creates a static library module for a given target (used for the files CMake compiles with extra CPU flags).
    // Without debug information, like the CMake Release build (-O3 -DNDEBUG, no -g).
    //
    pub fn createLibraryForTarget(self: *const Context, name: []const u8, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
        const module = self.b.createModule(.{
            .target = target,
            .optimize = self.optimize,
            .link_libc = true,
            .strip = true,
        });
        return self.b.addLibrary(.{
            .name = name,
            .linkage = .static,
            .root_module = module,
        });
    }

    //
    // Gets the target with extra CPU features, the equivalent of compiling with `-m<feature>` flags such as `-mavx2`
    // or `-march=armv8-a+crc+crypto`.
    //
    pub fn targetWithFeatures(self: *const Context, features: []const std.Target.Cpu.Feature.Set.Index) std.Build.ResolvedTarget {
        var query = self.target.query;
        for (features) |feature| {
            query.cpu_features_add.addFeature(feature);
        }
        return self.b.resolveTargetQuery(query);
    }
};

//
// Lists the C files of one directory of a dependency, sorted, as paths relative to the dependency's root: the
// equivalent of CMake's `file(GLOB "<directory>/*.c")`.
//
pub fn globCSources(b: *std.Build, dependency: *std.Build.Dependency, directory: []const u8) ![]const []const u8 {
    return globFiles(b, dependency, directory, ".c");
}

//
// Lists the files of one directory of a dependency with an extension, sorted, as paths relative to the dependency's
// root: the equivalent of CMake's `file(GLOB "<directory>/*<extension>")`.
//
pub fn globFiles(b: *std.Build, dependency: *std.Build.Dependency, directory: []const u8, extension: []const u8) ![]const []const u8 {
    const io = b.graph.io;
    var files: std.ArrayList([]const u8) = .empty;
    // A pattern in a directory that does not exist matches nothing, as in CMake (aws-c-common globs
    // "source/darwin/*.c" on Apple, a directory its releases no longer have).
    var dir = dependency.builder.build_root.handle.openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            return files.items;
        },
        else => {
            return err;
        },
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, extension)) {
            continue;
        }
        try files.append(b.allocator, b.fmt("{s}/{s}", .{ directory, entry.name }));
    }
    std.mem.sort([]const u8, files.items, {}, lessThan);
    return files.items;
}

//
// Lists the C files under a directory of a dependency and all its subdirectories, sorted: the equivalent of CMake's
// `file(GLOB_RECURSE "<directory>/*.c")`.
//
pub fn globCSourcesRecursive(b: *std.Build, dependency: *std.Build.Dependency, directory: []const u8) ![]const []const u8 {
    const io = b.graph.io;
    var dir = try dependency.builder.build_root.handle.openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(b.allocator);
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".c")) {
            continue;
        }
        try files.append(b.allocator, b.fmt("{s}/{s}", .{ directory, entry.path }));
    }
    std.mem.sort([]const u8, files.items, {}, lessThan);
    return files.items;
}

//
// Byte order of two strings, for sorting file lists.
//
fn lessThan(context: void, left: []const u8, right: []const u8) bool {
    _ = context;
    return std.mem.order(u8, left, right) == .lt;
}

//
// The name the module translated from the SDK headers the binding uses is imported under.
//
pub const aws_c_module_name = "aws-c";

//
// The SDK headers the S3 client binding (src/lib/s3-client.zig) uses, translated to Zig as the "aws-c" module.
//
const aws_c_header =
    \\#include <aws/auth/credentials.h>
    \\#include <aws/auth/signable.h>
    \\#include <aws/auth/signing.h>
    \\#include <aws/auth/signing_config.h>
    \\#include <aws/auth/signing_result.h>
    \\#include <aws/cal/hash.h>
    \\#include <aws/common/condition_variable.h>
    \\#include <aws/common/date_time.h>
    \\#include <aws/common/encoding.h>
    \\#include <aws/common/mutex.h>
    \\#include <aws/common/uri.h>
    \\#include <aws/common/xml_parser.h>
    \\#include <aws/http/request_response.h>
    \\#include <aws/io/channel_bootstrap.h>
    \\#include <aws/io/event_loop.h>
    \\#include <aws/io/host_resolver.h>
    \\#include <aws/io/retry_strategy.h>
    \\#include <aws/io/stream.h>
    \\#include <aws/s3/s3.h>
    \\#include <aws/s3/s3_client.h>
    \\#include <aws/s3/s3_endpoint_resolver.h>
    \\#include <aws/s3/private/s3_util.h>
    \\#include <aws/sdkutils/endpoints_rule_engine.h>
    \\
;

//
// Builds the SDK for the target, links it into the module and adds the "aws-c" module translated from its headers.
// Returns false when a lazy dependency still has to be fetched (the build runner fetches it and runs the build again).
//
pub fn addAwsSdk(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) !bool {
    const os = target.result.os.tag;
    const arch = target.result.cpu.arch;
    if (os != .linux and os != .windows and os != .macos) {
        std.log.err("The AWS SDK for C is only built for Linux, Windows and macOS, not {s}. See docs/aws-sdk.md.", .{@tagName(os)});
        std.process.exit(1);
    }
    // Zig uses the macOS SDK (Xcode's or the Command Line Tools', found with `xcrun --sdk macosx --show-sdk-path`)
    // only for a native build: a target whose operating system and ABI are not given (see
    // std/zig/system/darwin.zig and std/zig/LibCDirs.zig).
    if (os == .macos and !(target.query.isNativeOs() and target.query.isNativeAbi())) {
        std.log.err("The AWS SDK for C is only built for macOS natively on a Mac, with no -Dtarget (-Dcpu may be given). On Apple platforms aws-c-cal and aws-c-io are built from their darwin sources, which include the Security, Network and CoreFoundation framework headers of the macOS SDK; Zig does not ship those headers and only uses the macOS SDK for a native build, so they cannot be compiled for {s} here. See docs/aws-sdk.md.", .{try target.result.zigTriple(b.allocator)});
        std.process.exit(1);
    }
    if (arch != .x86_64 and arch != .aarch64) {
        std.log.err("The AWS SDK for C build only covers x86_64 and aarch64, not {s}.", .{@tagName(arch)});
        std.process.exit(1);
    }
    const host = b.graph.host.result;
    const context: Context = .{
        .b = b,
        .target = target,
        .optimize = .ReleaseFast,
        .isLinux = os == .linux,
        .isWindows = os == .windows,
        .isMacos = os == .macos,
        .isX86_64 = arch == .x86_64,
        .isAarch64 = arch == .aarch64,
        .isCrossCompiling = host.os.tag != os or host.cpu.arch != arch or host.abi != target.result.abi,
        .isMusl = target.result.abi.isMusl(),
    };

    const common = try aws_c_common.build(&context, b.dependency("aws-c-common", .{}));
    const checksums = try aws_checksums.build(&context, b.dependency("aws-checksums", .{}), common);

    // The crypto and TLS libraries are only built for Linux, where aws-c-cal uses aws-lc's libcrypto and aws-c-io
    // uses s2n-tls, and for macOS, where aws-c-io's USE_S2N option is on by default (aws-crt-cpp builds aws-lc and
    // s2n-tls there too, and aws-c-io picks Secure Transport or s2n-tls at run time; aws-c-cal uses CommonCrypto). On
    // Windows the SDK uses the operating system's BCrypt and SChannel.
    var crypto: ?*std.Build.Step.Compile = null;
    var s2n: ?*std.Build.Step.Compile = null;
    if (context.isLinux or context.isMacos) {
        const aws_lc_dependency = b.lazyDependency("aws-lc", .{}) orelse {
            return false;
        };
        const s2n_tls_dependency = b.lazyDependency("s2n-tls", .{}) orelse {
            return false;
        };
        crypto = try aws_lc.build(&context, aws_lc_dependency);
        s2n = try s2n_tls.build(&context, s2n_tls_dependency, crypto.?);
    }

    const cal = try aws_c_cal.build(&context, b.dependency("aws-c-cal", .{}), common, crypto);
    const io = try aws_c_io.build(&context, b.dependency("aws-c-io", .{}), common, cal, s2n);
    const compression = try aws_c_compression.build(&context, b.dependency("aws-c-compression", .{}), common);
    const http = try aws_c_http.build(&context, b.dependency("aws-c-http", .{}), io, compression);
    const sdkutils = try aws_c_sdkutils.build(&context, b.dependency("aws-c-sdkutils", .{}), common);
    const auth = try aws_c_auth.build(&context, b.dependency("aws-c-auth", .{}), sdkutils, cal, http);
    const s3 = try aws_c_s3.build(&context, b.dependency("aws-c-s3", .{}), auth, checksums);

    // The headers are preprocessed by Zig's C compiler (clang) before translate-c reads them, keeping the macro
    // definitions (-dD). translate-c's own preprocessor fails on the argument-counting macros aws/common/macros.h
    // expands in its static assertions (CALL_OVERLOAD_TEST), which clang's preprocessor expands correctly. The system
    // headers are left as #include directives (-fkeep-system-includes) for translate-c to read itself, because the
    // glibc headers clang expands declare _Float32 and friends in a way translate-c rejects.
    const header_files = b.addWriteFiles();
    const preprocess = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-E", "-dD", "-fkeep-system-includes", "-target", try target.result.zigTriple(b.allocator) });
    for ([_]*std.Build.Step.Compile{ common, checksums, cal, io, compression, http, sdkutils, auth, s3 }) |library| {
        preprocess.addPrefixedDirectoryArg("-I", library.getEmittedIncludeTree());
    }
    for (aws_c_io.publicDefines(&context)) |define| {
        preprocess.addArg(b.fmt("-D{s}", .{define}));
    }
    preprocess.addFileArg(header_files.add("aws-c.h", aws_c_header));
    preprocess.addArg("-o");
    const preprocessed_header = preprocess.addOutputFileArg("aws-c-preprocessed.h");
    // Translated without optimization: in the optimized modes the MinGW headers define fortified inline wrappers of
    // memset and friends, which translate-c turns into Zig that does not compile. The declarations are the same.
    const translate_c = b.addTranslateC(.{
        .root_source_file = preprocessed_header,
        .target = target,
        .optimize = .Debug,
    });
    module.addImport(aws_c_module_name, translate_c.createModule());

    for ([_]*std.Build.Step.Compile{ s3, auth, sdkutils, http, compression, io, cal, checksums, common }) |library| {
        module.linkLibrary(library);
    }
    if (s2n) |library| {
        module.linkLibrary(library);
    }
    if (crypto) |library| {
        module.linkLibrary(library);
    }
    return true;
}
