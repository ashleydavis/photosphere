const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const helpers = @import("test-helpers.zig");

//
// The fixture with the TypeScript output for this platform (generate.ts writes the Linux one,
// generate-installation-instructions.ts the Windows and macOS ones).
//
const platform_fixture = switch (builtin.os.tag) {
    .windows => "installation-instructions-win32.json",
    .macos => "installation-instructions-darwin.json",
    else => "installation-instructions.json",
};

test "showInstallationInstructions matches the TypeScript output of the platform" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    cli.picocolors.setColorSupportOverride(true);
    defer cli.picocolors.setColorSupportOverride(null);
    const fixture = try helpers.loadFixture(allocator, platform_fixture);
    for (fixture.array.items) |installationCase| {
        var stdout_capture = std.Io.Writer.Allocating.init(allocator);
        var stderr_capture = std.Io.Writer.Allocating.init(allocator);
        utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
        defer utils.console.setCapture(null, null);
        const missingTools = try helpers.stringArray(allocator, installationCase.object.get("missingTools").?);
        try cli.installation_instructions.showInstallationInstructions(allocator, missingTools);
        try std.testing.expectEqualStrings(helpers.stringField(installationCase, "output"), stdout_capture.written());
    }
}
