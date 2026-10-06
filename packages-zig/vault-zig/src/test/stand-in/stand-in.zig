const std = @import("std");
const builtin = @import("builtin");

//
// Stands in for the command-line tools the Linux and Windows keychain vaults run (`which`, `secret-tool` and
// `powershell`) and for a plain program the keychain-types tests run (`photosphere-stand-in-output`), so the vault
// tests never touch a real keychain. build.zig builds it at test time and installs a copy under each tool's name to a
// directory it puts first on the PATH of the test programs. The copy works out which tool it is from the name it
// was started with.
//
// Its state lives in files in the directory named by the PHOTOSPHERE_STAND_IN_STATE environment variable, which
// each test sets to a temporary directory of its own (see stand-ins.zig):
//   store.json      the keychain entries: account name to {"type","value"} for secret-tool, and account name to the
//                   JSON payload for PowerShell.
//   mode            how the tool misbehaves, when a test asks it to (see the modes below).
//   last-store-args the arguments of the last `secret-tool store`, as a JSON array.
//   last-store-stdin the input of the last `secret-tool store`.
//   last-get-args   the arguments of the last PowerShell script that reads a password, as a JSON array.
//

//
// The environment variable that names the directory holding the state of the stand-ins.
//
const STATE_VARIABLE = "PHOTOSPHERE_STAND_IN_STATE";

//
// The exit code of a stand-in that was run in a way no test expects.
//
const UNEXPECTED_EXIT_CODE = 99;

//
// What a stand-in does once it has run: the text it writes to stdout and stderr and its exit code.
//
const IOutcome = struct {
    // The text written to stdout.
    stdout: []const u8,

    // The text written to stderr.
    stderr: []const u8,

    // The exit code.
    code: u8,
};

//
// Makes the outcome of a stand-in from what it writes to stdout and stderr and its exit code.
//
fn outcome(stdout: []const u8, stderr: []const u8, code: u8) IOutcome {
    return .{
        .stdout = stdout,
        .stderr = stderr,
        .code = code,
    };
}

//
// The state a stand-in runs with.
//
const IStandIn = struct {
    // Allocates everything the stand-in needs (freed when it exits).
    allocator: std.mem.Allocator,

    // The I/O implementation.
    io: std.Io,

    // The directory holding the state of the stand-ins.
    stateDir: std.Io.Dir,

    // The contents of the mode file, trimmed ("" when there is none).
    mode: []const u8,

    //
    // Reads a state file, or returns null when it does not exist.
    //
    fn readStateFile(self: *const IStandIn, name: []const u8) !?[]const u8 {
        return self.stateDir.readFileAlloc(self.io, name, self.allocator, .unlimited) catch |err| {
            if (err == error.FileNotFound) {
                return null;
            }
            return err;
        };
    }

    //
    // Writes a state file.
    //
    fn writeStateFile(self: *const IStandIn, name: []const u8, data: []const u8) !void {
        try self.stateDir.writeFile(self.io, .{
            .sub_path = name,
            .data = data,
        });
    }

    //
    // Reads the keychain entries (an empty object when there are none).
    //
    fn readStore(self: *const IStandIn) !std.json.ObjectMap {
        const text = try self.readStateFile("store.json") orelse return .empty;
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, self.allocator, text, .{});
        return parsed.object;
    }

    //
    // Writes the keychain entries.
    //
    fn writeStore(self: *const IStandIn, store: std.json.ObjectMap) !void {
        const text = try std.json.Stringify.valueAlloc(self.allocator, std.json.Value{
            .object = store,
        }, .{});
        try self.writeStateFile("store.json", text);
    }

    //
    // Records arguments as a JSON array in a state file.
    //
    fn recordArgs(self: *const IStandIn, name: []const u8, args: []const []const u8) !void {
        try self.writeStateFile(name, try std.json.Stringify.valueAlloc(self.allocator, args, .{}));
    }
};

//
// Runs the tool named by the first argument and exits with its exit code.
//
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const statePath = init.environ_map.get(STATE_VARIABLE) orelse {
        std.debug.print("{s} is not set, so the stand-in has no state to run with\n", .{STATE_VARIABLE});
        std.process.exit(UNEXPECTED_EXIT_CODE);
    };
    var stateDir = std.Io.Dir.cwd().openDir(io, statePath, .{}) catch |err| {
        std.debug.print("Could not open the stand-in state directory {s}: {s}\n", .{ statePath, @errorName(err) });
        std.process.exit(UNEXPECTED_EXIT_CODE);
    };
    defer stateDir.close(io);

    var standIn: IStandIn = .{
        .allocator = allocator,
        .io = io,
        .stateDir = stateDir,
        .mode = "",
    };
    if (try standIn.readStateFile("mode")) |mode| {
        standIn.mode = std.mem.trim(u8, mode, " \r\n");
    }

    const toolName = toolNameOf(args[0]);
    const toolOutcome = if (std.mem.eql(u8, toolName, "which"))
        runWhich(&standIn)
    else if (std.mem.eql(u8, toolName, "secret-tool"))
        try runSecretTool(&standIn, args)
    else if (std.mem.eql(u8, toolName, "powershell"))
        try runPowerShell(&standIn, args)
    else if (std.mem.eql(u8, toolName, "photosphere-stand-in-output"))
        outcome("fake\n", "", 0)
    else
        outcome("", try std.fmt.allocPrint(allocator, "Unexpected command: {s}", .{toolName}), UNEXPECTED_EXIT_CODE);

    try std.Io.File.stdout().writeStreamingAll(io, toolOutcome.stdout);
    try std.Io.File.stderr().writeStreamingAll(io, toolOutcome.stderr);
    std.process.exit(toolOutcome.code);
}

//
// Returns the name of the tool a program path names: its base name without an .exe extension.
//
fn toolNameOf(programPath: []const u8) []const u8 {
    var baseName = programPath;
    if (std.mem.lastIndexOfAny(u8, programPath, "/\\")) |separatorIndex| {
        baseName = programPath[separatorIndex + 1 ..];
    }
    if (std.ascii.endsWithIgnoreCase(baseName, ".exe")) {
        return baseName[0 .. baseName.len - ".exe".len];
    }
    return baseName;
}

//
// `which secret-tool`: finds secret-tool, unless the mode is "missing-secret-tool".
//
fn runWhich(standIn: *const IStandIn) IOutcome {
    if (std.mem.eql(u8, standIn.mode, "missing-secret-tool")) {
        return outcome("", "", 1);
    }
    return outcome("/usr/bin/secret-tool\n", "", 0);
}

//
// Returns the index of the first argument equal to `name`, or null.
//
fn argIndex(args: []const []const u8, name: []const u8) ?usize {
    for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, name)) {
            return index;
        }
    }
    return null;
}

//
// `secret-tool lookup`, `store` (value from stdin), `search` (attribute lines on stderr) and `clear`, backed by the
// store file. The modes:
//   failing-store          `store` fails with exit code 2.
//   failing-search:<code>  `search` fails with the exit code, or is killed by a signal when the code is "signal".
//   unreadable-lookup      `lookup` of psi-empty prints nothing and of psi-broken fails.
//
fn runSecretTool(standIn: *const IStandIn, args: []const []const u8) !IOutcome {
    const allocator = standIn.allocator;
    if (args.len < 2) {
        return outcome("", "Missing secret-tool subcommand", UNEXPECTED_EXIT_CODE);
    }
    const subcommand = args[1];
    var store = try standIn.readStore();

    if (std.mem.eql(u8, subcommand, "lookup")) {
        // args: secret-tool lookup service photosphere account <keychainName>
        const keychainName = args[5];
        if (std.mem.eql(u8, standIn.mode, "unreadable-lookup")) {
            if (std.mem.eql(u8, keychainName, "psi-empty")) {
                return outcome("\n", "", 0);
            }
            if (std.mem.eql(u8, keychainName, "psi-broken")) {
                return outcome("", "cannot read", 5);
            }
        }
        if (store.get(keychainName)) |entry| {
            return outcome(entry.object.get("value").?.string, "", 0);
        }
        return outcome("", "No such secret", 1);
    }

    if (std.mem.eql(u8, subcommand, "store")) {
        // The stdin is read before failing as well. Failing without reading let this process exit before the caller
        // wrote the value, so the write got EPIPE and the test saw error.BrokenPipe instead of the exit code
        // (Release workflow, zig-unit-tests on ubuntu-latest: "set reports a failing secret-tool store with its exit
        // code and stderr", expected error.Thrown, found error.BrokenPipe).
        var stdinBuffer: [4096]u8 = undefined;
        var stdinReader = std.Io.File.stdin().readerStreaming(standIn.io, &stdinBuffer);
        const value = try stdinReader.interface.allocRemaining(allocator, .unlimited);
        if (std.mem.eql(u8, standIn.mode, "failing-store")) {
            return outcome("", "no daemon\n", 2);
        }
        try standIn.recordArgs("last-store-args", args);
        try standIn.writeStateFile("last-store-stdin", value);

        // Args: store --label=<name> service photosphere account <name> secrettype <type>
        var keychainName: []const u8 = "";
        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "--label=")) {
                keychainName = arg["--label=".len..];
            }
        }
        const secretType = if (argIndex(args, "secrettype")) |index| args[index + 1] else "plain";
        var entry: std.json.ObjectMap = .empty;
        try entry.put(allocator, "type", .{
            .string = secretType,
        });
        try entry.put(allocator, "value", .{
            .string = value,
        });
        try store.put(allocator, keychainName, .{
            .object = entry,
        });
        try standIn.writeStore(store);
        return outcome("", "", 0);
    }

    if (std.mem.eql(u8, subcommand, "search")) {
        const failingPrefix = "failing-search:";
        if (std.mem.startsWith(u8, standIn.mode, failingPrefix)) {
            const failure = standIn.mode[failingPrefix.len..];
            if (std.mem.eql(u8, failure, "signal")) {
                killSelf();
            }
            return outcome("", "search failed", try std.fmt.parseInt(u8, failure, 10));
        }

        // Emit attribute lines via stderr for matching entries.
        // If an "account" filter arg is present, emit only that entry.
        const accountFilter = if (argIndex(args, "account")) |index| args[index + 1] else null;
        var stderr: std.ArrayList(u8) = .empty;
        var iterator = store.iterator();
        while (iterator.next()) |storeEntry| {
            if (accountFilter != null and !std.mem.eql(u8, storeEntry.key_ptr.*, accountFilter.?)) {
                continue;
            }
            try stderr.print(allocator, "attribute.service = photosphere\n", .{});
            try stderr.print(allocator, "attribute.account = {s}\n", .{storeEntry.key_ptr.*});
            try stderr.print(allocator, "attribute.secrettype = {s}\n", .{storeEntry.value_ptr.object.get("type").?.string});
            try stderr.print(allocator, "\n", .{});
        }
        return outcome("", stderr.items, 0);
    }

    if (std.mem.eql(u8, subcommand, "clear")) {
        // args: secret-tool clear service photosphere account <keychainName>
        _ = store.orderedRemove(args[5]);
        try standIn.writeStore(store);
        return outcome("", "", 0);
    }

    return outcome("", try std.fmt.allocPrint(allocator, "Unexpected secret-tool subcommand: {s}", .{subcommand}), UNEXPECTED_EXIT_CODE);
}

//
// Ends this process with a signal, so its parent sees no exit code (POSIX only: a Windows process always has one).
//
fn killSelf() noreturn {
    if (builtin.os.tag == .windows) {
        std.debug.print("A Windows process cannot be killed by a signal\n", .{});
        std.process.exit(UNEXPECTED_EXIT_CODE);
    }
    std.posix.raise(.KILL) catch {};
    std.process.exit(UNEXPECTED_EXIT_CODE);
}

//
// Parses the single-quoted PowerShell string arguments that follow `prefix` in the script
// (unescaping ''), e.g. the three arguments of `PasswordCredential('a', 'b', 'c')`.
//
fn quotedArgsAfter(allocator: std.mem.Allocator, script: []const u8, prefix: []const u8) ![]const []const u8 {
    var quotedArgs: std.ArrayList([]const u8) = .empty;
    const start = (std.mem.indexOf(u8, script, prefix) orelse return quotedArgs.items) + prefix.len;
    var index = start;
    while (index < script.len and script[index] != ')') {
        if (script[index] != '\'') {
            index += 1;
            continue;
        }
        index += 1;
        var value: std.ArrayList(u8) = .empty;
        while (index < script.len) {
            if (script[index] == '\'') {
                if (index + 1 < script.len and script[index + 1] == '\'') {
                    try value.append(allocator, '\'');
                    index += 2;
                    continue;
                }
                index += 1;
                break;
            }
            try value.append(allocator, script[index]);
            index += 1;
        }
        try quotedArgs.append(allocator, value.items);
    }
    return quotedArgs.items;
}

//
// `powershell -NoProfile -Command <script>`: simulates the PasswordVault scripts of the Windows vault with the store
// file. With the mode "broken-powershell" every script fails, as on a machine where PowerShell cannot run, and with
// the mode "empty-password" a script that reads a password succeeds and writes nothing, as one holding a credential
// stored with an empty password does.
//
fn runPowerShell(standIn: *const IStandIn, args: []const []const u8) !IOutcome {
    const allocator = standIn.allocator;
    if (std.mem.eql(u8, standIn.mode, "broken-powershell")) {
        return outcome("", "not found", 1);
    }
    const script = args[args.len - 1];
    var store = try standIn.readStore();

    if (std.mem.indexOf(u8, script, "PSVersionTable") != null) {
        return outcome("5.1.0", "", 0);
    }

    if (std.mem.indexOf(u8, script, "Retrieve(") != null and std.mem.indexOf(u8, script, "Write-Output $cred.Password") != null) {
        // get
        try standIn.recordArgs("last-get-args", args);
        const quotedArgs = try quotedArgsAfter(allocator, script, "Retrieve(");
        if (std.mem.eql(u8, standIn.mode, "empty-password")) {
            return outcome("", "", 0);
        }
        if (store.get(quotedArgs[1])) |raw| {
            return outcome(raw.string, "", 0);
        }
        return outcome("", "Object reference not set to an instance of an object.", 1);
    }

    if (std.mem.indexOf(u8, script, "PasswordCredential(") != null) {
        // set
        const quotedArgs = try quotedArgsAfter(allocator, script, "PasswordCredential(");
        try store.put(allocator, quotedArgs[1], .{
            .string = quotedArgs[2],
        });
        try standIn.writeStore(store);
        return outcome("", "", 0);
    }

    if (std.mem.indexOf(u8, script, "FindAllByResource(") != null and std.mem.indexOf(u8, script, "Write-Output $cred.UserName") != null) {
        // list
        return outcome(try std.mem.join(allocator, "\n", store.keys()), "", 0);
    }

    if (std.mem.indexOf(u8, script, "Retrieve(") != null and std.mem.indexOf(u8, script, "$vault.Remove(") != null) {
        // delete
        const quotedArgs = try quotedArgsAfter(allocator, script, "Retrieve(");
        _ = store.orderedRemove(quotedArgs[1]);
        try standIn.writeStore(store);
        return outcome("", "", 0);
    }

    return outcome("", try std.fmt.allocPrint(allocator, "Unrecognised PowerShell script: {s}", .{script}), UNEXPECTED_EXIT_CODE);
}
