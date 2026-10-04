const std = @import("std");
const ziggy = @import("ziggy-core");
const example = @import("ziggy-example-core");

const FakeShell = ziggy.fake_shell.FakeShell;

//
// Creates a core whose shell answers dialogs with the fake shell's callback, which reports what it was asked as its answer.
//
fn createCore(shell: *FakeShell) !*ziggy.core.Core {
    return try ziggy.core.Core.create(std.testing.allocator, shell.config(2, 2), example.app);
}

test "pick-files asks for an open dialog with the title and replies with the paths" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"pick-files\",\"data\":\"Pick some files\"}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":true,\"data\":[\"kind0\",\"Pick some files\",\"-\"]}");
}

test "pick-files with no title uses a default one" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"pick-files\",\"data\":null}");
    try shell.expectMessageContaining("[\"kind0\",\"Select Files\",\"-\"]");
}

test "pick-folder asks for a folder dialog with the title from the options and replies with one path" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    core.postMessage("{\"id\":2,\"channel\":\"pick-folder\",\"data\":{\"title\":\"Pick a folder\"}}");
    try shell.expectMessageContaining("{\"id\":2,\"ok\":true,\"data\":\"kind2\"}");
}

test "pick-folder with no options uses a default title" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    core.postMessage("{\"id\":2,\"channel\":\"pick-folder\",\"data\":null}");
    try shell.expectMessageContaining("{\"id\":2,\"ok\":true,\"data\":\"kind2\"}");
}

test "pick-file is a save dialog with the suggested name and replies with one path" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    core.postMessage("{\"id\":3,\"channel\":\"pick-file\",\"data\":\"photo.jpg\"}");
    try shell.expectMessageContaining("{\"id\":3,\"ok\":true,\"data\":\"kind1\"}");
}

test "a cancelled dialog is a reply of null, as Electron's undefined" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var config = shell.config(2, 2);
    config.pick_paths = FakeShell.pickNothing;
    const core = try ziggy.core.Core.create(std.testing.allocator, config, example.app);
    defer core.destroy();
    core.postMessage("{\"id\":4,\"channel\":\"pick-files\",\"data\":\"T\"}");
    try shell.expectMessageContaining("{\"id\":4,\"ok\":true,\"data\":null}");
    core.postMessage("{\"id\":5,\"channel\":\"pick-folder\",\"data\":null}");
    try shell.expectMessageContaining("{\"id\":5,\"ok\":true,\"data\":null}");
    core.postMessage("{\"id\":6,\"channel\":\"pick-file\",\"data\":\"x\"}");
    try shell.expectMessageContaining("{\"id\":6,\"ok\":true,\"data\":null}");
}

test "a shell with no dialog callback gives an error reply naming what is missing" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var config = shell.config(2, 2);
    config.pick_paths = null;
    const core = try ziggy.core.Core.create(std.testing.allocator, config, example.app);
    defer core.destroy();
    core.postMessage("{\"id\":7,\"channel\":\"pick-folder\",\"data\":null}");
    try shell.expectMessageContaining("{\"id\":7,\"ok\":false,\"error\":\"HostCallbackMissing\"}");
}
