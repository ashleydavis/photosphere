const std = @import("std");

//
// Zig's translate-c cannot read the headers of the Windows SDK, which a build for the MSVC ABI is given (they use Microsoft's suffixes
// on integer constants, such as 0xffffffffui32, and other extensions). The MinGW-w64 headers Zig ships declare the same things, and the
// two ABIs lay structs out and call functions the same way on Windows, so C headers are translated for the -gnu ABI of a Windows MSVC
// target, and what is translated is still compiled and linked for the MSVC target.
//

//
// Returns the target query C headers are translated for: the -gnu ABI of a Windows MSVC target, and the target itself for any other.
//
pub fn translateQuery(query: std.Target.Query, result: std.Target) std.Target.Query {
    if (result.os.tag != .windows or result.abi != .msvc) {
        return query;
    }
    var translate_query = query;
    translate_query.abi = .gnu;
    return translate_query;
}

//
// Returns the target C headers are translated for (see translateQuery).
//
pub fn translateTarget(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.ResolvedTarget {
    if (target.result.os.tag != .windows or target.result.abi != .msvc) {
        return target;
    }
    return b.resolveTargetQuery(translateQuery(target.query, target.result));
}

test "a Windows MSVC target is translated for the -gnu ABI" {
    const query = try std.Target.Query.parse(.{
        .arch_os_abi = "x86_64-windows-msvc",
    });
    const result = try std.zig.system.resolveTargetQuery(std.testing.io, query);
    try std.testing.expectEqual(std.Target.Abi.gnu, translateQuery(query, result).abi.?);
    try std.testing.expectEqual(std.Target.Os.Tag.windows, translateQuery(query, result).os_tag.?);
    try std.testing.expectEqual(std.Target.Cpu.Arch.x86_64, translateQuery(query, result).cpu_arch.?);
}

test "any other target is translated for itself" {
    for ([_][]const u8{ "x86_64-windows-gnu", "x86_64-linux-gnu", "aarch64-macos", "aarch64-linux-android" }) |name| {
        const query = try std.Target.Query.parse(.{
            .arch_os_abi = name,
        });
        const result = try std.zig.system.resolveTargetQuery(std.testing.io, query);
        try std.testing.expect(translateQuery(query, result).eql(query));
    }
}
