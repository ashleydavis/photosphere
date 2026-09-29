const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli-zig");
const node_utils = @import("node-utils-zig");
const helpers = @import("test-helpers.zig");
const bug = cli.bug;

//
// Points the process environment at a test root: the temp dir (getProcessTmpDir) is <root>/tmp.
//
fn useTmpDir(allocator: std.mem.Allocator, root: []const u8) !void {
    const map = try allocator.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(allocator);
    try map.put("PHOTOSPHERE_TMP_DIR", root);
    node_utils.process_env.setEnvironMap(map);
}

//
// Writes a log file into the log directory and sets its modification time (in seconds since the epoch).
//
fn writeLogFile(allocator: std.mem.Allocator, logsDir: []const u8, name: []const u8, modifiedSeconds: i64) ![]const u8 {
    const io = std.testing.io;
    const filePath = try std.fs.path.join(allocator, &.{ logsDir, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filePath, .data = "log\n" });
    const file = try std.Io.Dir.cwd().openFile(io, filePath, .{ .mode = .read_write });
    defer file.close(io);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, modifiedSeconds) * std.time.ns_per_s) } });
    return filePath;
}

test "createGitHubIssueUrl encodes the title and the body like URLSearchParams" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The expected URL is what `new URLSearchParams({ title, body, labels: "bug" }).toString()` gives.
    const url = try bug.createGitHubIssueUrl(allocator, "a b&c=d\n~!'()*-._\u{e9}/?#+%", "## Body\nline");
    try std.testing.expectEqualStrings("https://github.com/ashleydavis/photosphere/issues/new?title=a+b%26c%3Dd%0A%7E%21%27%28%29*-._%C3%A9%2F%3F%23%2B%25&body=%23%23+Body%0Aline&labels=bug", url);
}

test "getLogHeader returns the header of the log file, or says why there is none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const root = try helpers.makeTempDir(allocator, "bug-log-header");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    try std.testing.expectEqualStrings("No log file available", try bug.getLogHeader(allocator, io, null));
    try std.testing.expectEqualStrings("No log file available", try bug.getLogHeader(allocator, io, try std.fs.path.join(allocator, &.{ root, "missing.log" })));

    // Everything up to and including the marker.
    const withMarker = try std.fs.path.join(allocator, &.{ root, "marker.log" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = withMarker, .data = "Version: 1\nPlatform: x\n--- Log Start ---\nbody\n" });
    try std.testing.expectEqualStrings("Version: 1\nPlatform: x\n--- Log Start ---", try bug.getLogHeader(allocator, io, withMarker));

    // Without the marker, the first 50 lines.
    var lines: std.ArrayList(u8) = .empty;
    for (1..61) |lineNumber| {
        try lines.print(allocator, "line {d}\n", .{lineNumber});
    }
    const withoutMarker = try std.fs.path.join(allocator, &.{ root, "plain.log" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = withoutMarker, .data = lines.items });
    const header = try bug.getLogHeader(allocator, io, withoutMarker);
    try std.testing.expect(std.mem.startsWith(u8, header, "line 1\nline 2\n"));
    try std.testing.expect(std.mem.endsWith(u8, header, "\nline 49\nline 50"));

    // A path that cannot be read as a file.
    try std.testing.expect(std.mem.startsWith(u8, try bug.getLogHeader(allocator, io, root), "Error reading log file: "));
}

test "getLatestLogFile returns the newest psi-*.log file of the log directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const root = try helpers.makeTempDir(allocator, "bug-latest-log");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try useTmpDir(allocator, root);
    defer node_utils.process_env.setEnvironMap(null);

    // There is no log directory yet.
    try std.testing.expect(bug.getLatestLogFile(allocator, io) == null);

    const logsDir = try std.fs.path.join(allocator, &.{ root, "tmp", "photosphere", "logs" });
    try std.Io.Dir.cwd().createDirPath(io, logsDir);
    try std.testing.expect(bug.getLatestLogFile(allocator, io) == null);

    _ = try writeLogFile(allocator, logsDir, "psi-older.log", 1_700_000_000);
    const newest = try writeLogFile(allocator, logsDir, "psi-newest.log", 1_700_000_200);
    _ = try writeLogFile(allocator, logsDir, "psi-middle.log", 1_700_000_100);
    _ = try writeLogFile(allocator, logsDir, "other.log", 1_700_000_300);
    _ = try writeLogFile(allocator, logsDir, "psi-text.txt", 1_700_000_400);
    try std.testing.expectEqualStrings(newest, bug.getLatestLogFile(allocator, io).?);
}

test "generateBugReportTemplate fills in the details of the bug and the system" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const root = try helpers.makeTempDir(allocator, "bug-template");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try useTmpDir(allocator, root);
    defer node_utils.process_env.setEnvironMap(null);

    const template = try bug.generateBugReportTemplate(allocator, io, .{
        .platform = "linux",
        .arch = "x64",
        .release = "6.1",
        .nodeVersion = "v24",
        .workingDirectory = "/work",
    }, .{
        .imagemagick = "ImageMagick v7 (magick)",
        .ffmpeg = "ffmpeg v6",
        .ffprobe = "Not available",
    }, "1.2.3", .{
        .title = "Title",
        .description = "What happened",
        .stepsToReproduce = "1. One\n2. Two",
        .expectedBehavior = "Expected",
        .actualBehavior = "Actual",
    }, "Header\n--- Log Start ---");
    try std.testing.expectEqualStrings(
        \\## Bug Description
        \\What happened
        \\
        \\## Steps to Reproduce
        \\1. One
        \\2. Two
        \\
        \\## Expected Behavior
        \\Expected
        \\
        \\## Actual Behavior
        \\Actual
        \\
        \\## System Information
        \\- Photosphere Version: 1.2.3
        \\- Platform: linux x64
        \\- OS Release: 6.1
        \\- Node.js Version: v24
        \\
        \\## Tool Versions
        \\- ImageMagick: ImageMagick v7 (magick)
        \\- FFmpeg: ffmpeg v6
        \\- FFprobe: Not available
        \\
        \\## Log Header
        \\```
        \\Header
        \\--- Log Start ---
        \\```
        \\
        \\## Log File
        \\Please attach the full log file located at:
        \\`No log file available`
        \\
        \\You can drag and drop the log file into this issue, or copy and paste its contents into a code block.
        \\
        \\## Additional Context
        \\<!-- Add any other context about the problem here -->
        \\
        \\
    , template);
}

test "getSystemInfo describes this system like Node's os and process" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    const systemInfo = try bug.getSystemInfo(allocator, io);
    const expectedPlatform = switch (builtin.os.tag) {
        .windows => "win32",
        .macos => "darwin",
        else => "linux",
    };
    try std.testing.expectEqualStrings(expectedPlatform, systemInfo.platform);
    try std.testing.expectEqualStrings(cli.file_logger.osArch(), systemInfo.arch);
    try std.testing.expect(systemInfo.release.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, systemInfo.nodeVersion, "zig-"));
    try std.testing.expectEqualStrings(try std.process.currentPathAlloc(io, allocator), systemInfo.workingDirectory);
}

test "powerShellPath finds Windows PowerShell under SYSTEMROOT, windir or C:\\Windows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const map = try allocator.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(allocator);
    node_utils.process_env.setEnvironMap(map);
    defer node_utils.process_env.setEnvironMap(null);

    try std.testing.expectEqualStrings("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", try cli.open.powerShellPath(allocator));
    try map.put("windir", "D:\\Win");
    try std.testing.expectEqualStrings("D:\\Win\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", try cli.open.powerShellPath(allocator));
    try map.put("SYSTEMROOT", "E:\\Root");
    try std.testing.expectEqualStrings("E:\\Root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", try cli.open.powerShellPath(allocator));
}

test "openCommand runs the opener of the platform like the open package" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const map = try allocator.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(allocator);
    try map.put("SYSTEMROOT", "C:\\Root");
    node_utils.process_env.setEnvironMap(map);
    defer node_utils.process_env.setEnvironMap(null);

    const target = "https://example.com/?a=b";
    const openerCommand = try cli.open.openCommand(allocator, target);
    if (builtin.os.tag == .windows) {
        // The base64 of `Start "https://example.com/?a=b"` in UTF-16LE (Buffer.from(..., 'utf16le').toString('base64')).
        try std.testing.expectEqualStrings("C:\\Root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", openerCommand.command);
        const expectedArguments = [_][]const u8{ "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", "UwB0AGEAcgB0ACAAIgBoAHQAdABwAHMAOgAvAC8AZQB4AGEAbQBwAGwAZQAuAGMAbwBtAC8APwBhAD0AYgAiAA==" };
        try std.testing.expectEqual(expectedArguments.len, openerCommand.cliArguments.len);
        for (expectedArguments, openerCommand.cliArguments) |expected, actual| {
            try std.testing.expectEqualStrings(expected, actual);
        }
    }
    else {
        try std.testing.expectEqualStrings(if (builtin.os.tag == .macos) "open" else "xdg-open", openerCommand.command);
        try std.testing.expectEqual(@as(usize, 1), openerCommand.cliArguments.len);
        try std.testing.expectEqualStrings(target, openerCommand.cliArguments[0]);
    }
}

//
// Windows: says whether a process is in a job object (kernel32).
//
extern "kernel32" fn IsProcessInJob(ProcessHandle: std.os.windows.HANDLE, JobHandle: ?std.os.windows.HANDLE, Result: *std.os.windows.BOOL) callconv(.winapi) std.os.windows.BOOL;

//
// Windows: waits until a handle is signaled or the timeout elapses (kernel32).
//
extern "kernel32" fn WaitForSingleObject(hHandle: std.os.windows.HANDLE, dwMilliseconds: std.os.windows.DWORD) callconv(.winapi) std.os.windows.DWORD;

test "on Windows the opener is started attached, so it ends when the CLI's job handle closes, as under Bun" {
    if (builtin.os.tag != .windows) {
        // Job objects exist only on Windows; elsewhere the opener is started detached.
        return error.SkipZigTest;
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // `pause` waits for a key on its stdin, a pipe nothing is written to, so it runs until it is killed.
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "cmd.exe", "/c", "pause" },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const process = child.id.?;
    const job = cli.open.startAttachedToThisProcess(allocator, process) orelse return error.OpenerNotPutInAJob;

    var inJob: std.os.windows.BOOL = .FALSE;
    try std.testing.expect(IsProcessInJob(process, job, &inJob).toBool());
    try std.testing.expect(inJob.toBool());

    // The handle closes when the CLI exits; closing it here ends the opener the same way.
    const wait_object_0: std.os.windows.DWORD = 0;
    try std.testing.expect(WaitForSingleObject(process, 0) != wait_object_0);
    std.os.windows.CloseHandle(job);
    try std.testing.expectEqual(wait_object_0, WaitForSingleObject(process, 10_000));
    child.stdin.?.close(std.testing.io);
    std.os.windows.CloseHandle(process);
    std.os.windows.CloseHandle(child.thread_handle);
}

test "getLatestLogFile breaks a tie in modification time by the order readdirSync lists the names in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const root = try helpers.makeTempDir(allocator, "bug-latest-log-tie");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try useTmpDir(allocator, root);
    defer node_utils.process_env.setEnvironMap(null);

    const logsDir = try std.fs.path.join(allocator, &.{ root, "tmp", "photosphere", "logs" });
    try std.Io.Dir.cwd().createDirPath(io, logsDir);

    // Written in an order that is not the order of their names, so the directory does not list them sorted.
    var expected: []const u8 = "";
    for ([_][]const u8{ "psi-m.log", "psi-z.log", "psi-c.log", "psi-x.log", "psi-a.log", "psi-q.log", "psi-f.log" }) |name| {
        const filePath = try writeLogFile(allocator, logsDir, name, 1_700_000_000);
        if (std.mem.eql(u8, name, "psi-a.log")) {
            expected = filePath;
        }
    }

    // Node lists a directory sorted by name (libuv's scandir), except on Windows, where the file system's own order
    // is what both list, and the stable sort by time keeps that order among files modified at the same time.
    if (builtin.os.tag != .windows) {
        try std.testing.expectEqualStrings(expected, bug.getLatestLogFile(allocator, io).?);
    }
}

test "getLogHeader reports a directory as readFileSync does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const root = try helpers.makeTempDir(allocator, "bug-log-header-dir");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    try std.testing.expectEqualStrings("Error reading log file: EISDIR: illegal operation on a directory, read", try bug.getLogHeader(allocator, io, root));
}
