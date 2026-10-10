const std = @import("std");
const ziggy = @import("ziggy-core");
const example = @import("ziggy-example-core");

const FakeShell = ziggy.fake_shell.FakeShell;

test "the example's page query says the test mode switch and nothing else" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), example.app);
    defer core.destroy();
    const without = try example.app.page_query.?(core, std.testing.allocator, false);
    defer std.testing.allocator.free(without);
    try std.testing.expectEqualStrings("", without);
    const with = try example.app.page_query.?(core, std.testing.allocator, true);
    defer std.testing.allocator.free(with);
    try std.testing.expectEqualStrings("testMode=1", with);
}

test "the example core gives the page an empty query outside test mode" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), example.app);
    defer core.destroy();
    try std.testing.expectEqualStrings("", try core.pageQuery());
}
