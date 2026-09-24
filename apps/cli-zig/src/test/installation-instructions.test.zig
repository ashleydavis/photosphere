const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const helpers = @import("test-helpers.zig");

test "showInstallationInstructions matches the TypeScript output on Linux" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    cli.picocolors.setColorSupportOverride(true);
    defer cli.picocolors.setColorSupportOverride(null);
    const fixture = try helpers.loadFixture(allocator, "installation-instructions.json");
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
