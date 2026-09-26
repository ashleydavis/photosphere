const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const errors = utils.errors;
const toml = @import("toml.zig");
const yaml = @import("yaml.zig");
const process_env = @import("process-env.zig");

//
// Sleeps for the given number of milliseconds. Kept local rather than imported from the `utils`
// package so this low-level module does not pull the whole `utils` barrel (and its ESM-only
// transitive dependencies) into `node-utils`'s test path.
// (Zig: takes fractional milliseconds like setTimeout, which the randomized backoff passes.)
//
fn sleep(io: std.Io, timeMs: f64) !void {
    try io.sleep(.fromNanoseconds(@intFromFloat(timeMs * std.time.ns_per_ms)), .awake);
}

//
// The base delay before an optimistic update retries after losing to another writer. Retrying
// immediately makes things worse: the losers re-read and re-write straight away, which keeps the
// file changing and starves everyone, so a burst of concurrent writers exhausts its retries
// instead of making progress. The wait doubles with each attempt and is randomized, so writers
// that collided spread out rather than colliding again in lockstep.
//
const UPDATE_BACKOFF_BASE_MS = 5;

//
// The longest a single backoff waits, so a busy file never stalls a writer for long.
//
const UPDATE_BACKOFF_MAX_MS = 250;

//
// How long an update lock may sit untouched before it is treated as abandoned by a process that
// died holding it, and broken. Far longer than any read-modify-write takes.
//
const LOCK_STALE_MS = 30000;

//
// How many times to poll for the update lock before giving up on it. Waiting for the lock is not
// the same as losing a write race: the holder is making progress and we simply have to wait our
// turn, so this is deliberately generous and is counted separately from the caller's retry budget.
// Spending the caller's retries on waiting would make a slow write by one process look like a
// failure to every other process.
//
const LOCK_WAIT_ATTEMPTS = 50;

//
// How many times a rename into place is retried when the operating system refuses it, and the base
// wait between tries. The waits grow, so ten attempts cover a little over a second in total.
//
const RENAME_RETRY_ATTEMPTS = 10;

//
// The base wait between tries of a refused rename (see RENAME_RETRY_ATTEMPTS).
//
const RENAME_RETRY_DELAY_MS = 20;

//
// Equivalent of `crypto.randomUUID()`: a random version 4 UUID.
//
fn randomUUID(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    return generator.generate(allocator, io);
}

//
// Renames a freshly written temporary file over its target, retrying the refusals Windows gives while
// something else has the target open.
//
// Writing to a temporary file and renaming it over the target is atomic on POSIX whatever else is
// reading, and is how every write here is made safe. Windows does not allow it: a rename onto a path
// another handle has open fails outright with EPERM, and virus scanners and the search indexer open
// files behind your back, so the refusal is transient and arrives without warning.
//
// The desktop app hit exactly that on the windows-latest runner, failing a smoke test with
// "EPERM: operation not permitted, rename 'databases.toml.tmp-...' -> 'databases.toml'" while opening
// a database. The update lock beside the file does not help, because it only keeps writers apart and
// this is a reader, or the operating system itself, holding the target.
//
// Only the refusals that come of contention are retried. Anything else, a missing directory or a bad
// path, is thrown on the first attempt as it always was.
//
fn renameIntoPlace(io: std.Io, tempPath: []const u8, filePath: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        cwd.rename(tempPath, cwd, filePath, io) catch |err| {
            // (Zig: EPERM is PermissionDenied, EACCES is AccessDenied and EBUSY is FileBusy.)
            const refusedForContention = err == error.PermissionDenied or err == error.AccessDenied or err == error.FileBusy;
            if (!refusedForContention or attempt >= RENAME_RETRY_ATTEMPTS) {
                return err;
            }
            try sleep(io, @floatFromInt(RENAME_RETRY_DELAY_MS * (attempt + 1)));
            continue;
        };
        return;
    }
}

//
// Ensures that the directory exists. If the directory structure does not exist, it is created.
// Like fs-extra's ensureDir, but using native fs.promises.
//
pub fn ensureDir(io: std.Io, dirPath: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dirPath) catch |err| {
        // With recursive: true, mkdir should not throw EEXIST if directory exists
        // But if it does, or if path exists as a file, handle it
        // (Zig reports a path that exists as a file as NotDir where Node reports EEXIST.)
        if (err == error.PathAlreadyExists or err == error.NotDir) {
            // Verify it's actually a directory
            const stats = try cwd.statFile(io, dirPath, .{});
            if (stats.kind != .directory) {
                return errors.throwError("Path exists but is not a directory: {s}", .{dirPath});
            }
        }
        else {
            return err;
        }
    };
}

//
// Ensures that the directory containing the file exists. If the directory structure does not exist, it is created.
//
pub fn ensureFileDir(io: std.Io, filePath: []const u8) !void {
    const dirPath = std.fs.path.dirname(filePath) orelse ".";
    return ensureDir(io, dirPath);
}

//
// Checks if a path exists (file or directory).
//
pub fn pathExists(io: std.Io, filePath: []const u8) bool {
    std.Io.Dir.cwd().access(io, filePath, .{}) catch {
        return false;
    };
    return true;
}

//
// Removes a file or directory. Works like fs-extra's remove.
//
pub fn remove(io: std.Io, targetPath: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const stats = cwd.statFile(io, targetPath, .{}) catch |err| {
        // If file/directory doesn't exist, that's fine (like fs-extra behavior)
        if (err == error.FileNotFound) {
            return;
        }
        return err;
    };

    if (stats.kind == .directory) {
        try cwd.deleteTree(io, targetPath);
    }
    else {
        cwd.deleteFile(io, targetPath) catch |err| {
            if (err != error.FileNotFound) {
                return err;
            }
        };
    }
}

//
// Outputs a file ensuring the directory exists. Like fs-extra's outputFile.
// The write is atomic: data is written to a unique temporary file in the same
// directory and then renamed into place. Because rename is atomic, a concurrent
// reader never sees a half-written file and two concurrent writers cannot
// interleave their bytes into a corrupt result (the last rename wins, and every
// intermediate state is a complete file). The temp name uses a fresh UUID so
// overlapping writes to the same target never share a temp file.
// The TypeScript `options` (encoding and mode) are not ported: data is written as given with default permissions.
//
pub fn outputFile(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, data: []const u8) !void {
    try ensureFileDir(io, filePath);
    const tempPath = try std.fmt.allocPrint(allocator, "{s}.tmp-{s}", .{ filePath, try randomUUID(allocator, io) });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tempPath, .data = data });
    try renameIntoPlace(io, tempPath, filePath);
}

//
// Reads a JSON file and parses it. Like fs-extra's readJson.
// The TypeScript `options` (encoding and flag) are not ported: the file is read as UTF-8.
//
pub fn readJson(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !std.json.Value {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, data, .{});
}

//
// Reads a TOML file and parses it.
//
pub fn readToml(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !toml.TomlValue {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
    return toml.parse(allocator, data);
}

//
// Writes an object to a TOML file, creating parent directories as needed.
//
pub fn writeToml(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, object: toml.TomlValue) !void {
    const tomlString = try toml.stringify(allocator, object);
    try outputFile(allocator, io, filePath, tomlString);
}

//
// Reads a YAML file and parses it, returning undefined when the file does not exist.
//
// Absence is not an error here, unlike readToml, because the one YAML file the app keeps is its
// configuration and that file does not exist until something writes it. Every caller would otherwise
// have to check for the file first, and a check followed by a read is two steps a concurrent writer
// can arrive between.
//
// An empty file parses to undefined rather than to an object, which is what js-yaml returns for a
// document with nothing in it.
//
pub fn readYaml(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?std.json.Value {
    const data = std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited) catch |err| {
        if (err == error.FileNotFound) {
            return null;
        }
        return err;
    };

    const parsed = try yaml.load(allocator, data);
    if (parsed == .null) {
        return null;
    }
    return parsed;
}

// Not ported: writeYaml (not used by replicate or verify).

//
// The parse and serialize functions updateYaml hands to updateFileOptimistic (the arrow functions in
// TypeScript).
//
const YamlParse = struct {
    // The value an empty document parses to.
    fallback: std.json.Value,

    //
    // Parses the text (`yaml.load(raw)`), using the fallback for an empty document.
    //
    pub fn run(self: *const YamlParse, allocator: std.mem.Allocator, raw: []const u8) !std.json.Value {
        const parsed = try yaml.load(allocator, raw);
        if (parsed == .null) {
            return self.fallback;
        }
        return parsed;
    }
};

//
// Serializes the value (`yaml.dump(value)`).
//
const YamlSerialize = struct {
    //
    // Dumps the value.
    //
    pub fn run(self: *const YamlSerialize, allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
        _ = self;
        return yaml.dump(allocator, value);
    }
};

//
// Updates a YAML file as an optimistic read-modify-write. Same semantics as updateToml: it reads the
// current parsed contents (or `fallback` when the file does not exist yet), passes them to `mutator`,
// and writes the returned value back atomically, reloading and re-applying if another writer got
// there first, up to `retries` times before throwing.
//
// In Zig the mutator is a value with a method `run(self, allocator, current: std.json.Value) !std.json.Value`.
//
pub fn updateYaml(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, fallback: std.json.Value, mutator: anytype, retries: u32) !void {
    const parse: YamlParse = .{ .fallback = fallback };
    const serialize: YamlSerialize = .{};
    try updateFileOptimistic(std.json.Value, allocator, io, filePath, fallback, mutator, &parse, &serialize, retries);
}

//
// Reads a file's raw bytes, or null when it does not exist yet.
//
fn readRawFileBytes(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?[]const u8 {
    if (!pathExists(io, filePath)) {
        return null;
    }
    return try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
}

//
// A cheap fingerprint of a file used to detect whether it changed between our read and our write
// without re-reading its contents. Undefined when the file does not exist. It uses only fields
// available on every platform we target (Node on Linux/macOS/Windows and the mobile stat shim):
// size and last-modified time. It deliberately avoids inode/nanosecond fields, which are absent on
// mobile and unreliable on Windows. The trade-off is that two writes producing an identical size in
// the same millisecond would not be told apart, which the optimistic retry accepts.
//
const IFileFingerprint = struct {
    // Last-modified time in milliseconds since the epoch.
    modifiedMs: i64,

    // File size in bytes.
    size: u64,
};

//
// Returns a fingerprint of the file at the given path, or null when it does not exist.
// The single stat is deliberate: checking for the file and then stat'ing it would be two steps,
// and a file that is deleted in between (an update lock being released, for instance) would make
// the stat fail even though "it is not there" is an answer this is meant to return.
//
fn fileFingerprint(io: std.Io, filePath: []const u8) !?IFileFingerprint {
    const stats = std.Io.Dir.cwd().statFile(io, filePath, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return null;
        }
        return err;
    };
    // (Zig: stats.mtime.getTime() is the modification time in whole milliseconds, rounded down.)
    return .{
        .modifiedMs = @intCast(@divFloor(stats.mtime.nanoseconds, std.time.ns_per_ms)),
        .size = stats.size,
    };
}

//
// Reports whether two fingerprints describe the same file state. Two absent files (both
// undefined) count as unchanged.
//
fn fingerprintsMatch(before: ?IFileFingerprint, after: ?IFileFingerprint) bool {
    if (before == null or after == null) {
        return before == null and after == null;
    }
    return before.?.modifiedMs == after.?.modifiedMs and before.?.size == after.?.size;
}

//
// Equivalent of `fs.rm(targetPath, { force: true })` for a file: a missing file is not an error.
//
fn removeFileForce(io: std.Io, targetPath: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, targetPath) catch |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    };
}

//
// Tries to take the exclusive lock guarding updates to a file, without waiting. Creating the lock
// file with the 'wx' flag is a single atomic operation in the filesystem: exactly one caller can
// create it, and everyone else gets EEXIST. That is what makes the update safe. A check-then-create
// would not be, because two callers could both pass the check before either created the file.
//
// A lock left behind by a process that died while holding it would otherwise block every later
// update forever, so a lock older than LOCK_STALE_MS is broken. The threshold is far longer than
// any read-modify-write takes, so a live holder is never robbed of its lock.
//
fn tryTakeUpdateLock(io: std.Io, lockPath: []const u8) !bool {
    if (std.Io.Dir.cwd().createFile(io, lockPath, .{ .exclusive = true })) |lockHandle| {
        lockHandle.close(io);
        return true;
    }
    else |err| {
        // Anything other than "someone else holds it" is a real problem.
        if (err != error.PathAlreadyExists) {
            return err;
        }
    }

    const lockFingerprint = try fileFingerprint(io, lockPath);
    if (lockFingerprint != null and std.Io.Timestamp.now(io, .real).toMilliseconds() - lockFingerprint.?.modifiedMs > LOCK_STALE_MS) {
        try removeFileForce(io, lockPath);
    }

    return false;
}

//
// Equivalent of `Math.random()`: a random number in [0, 1).
//
fn mathRandom(io: std.Io) f64 {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const random_bits = std.mem.readInt(u64, &random_bytes, .little) >> 11;
    return @as(f64, @floatFromInt(random_bits)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
}

//
// Returns how long to wait before another attempt: a randomized delay that grows with each one.
//
fn updateBackoffMs(io: std.Io, attempt: u32) f64 {
    return mathRandom(io) * @min(@as(f64, UPDATE_BACKOFF_MAX_MS), UPDATE_BACKOFF_BASE_MS * std.math.pow(f64, 2, @floatFromInt(attempt)));
}

//
// Waits for the exclusive lock guarding updates to a file, and reports whether it was taken.
//
fn takeUpdateLock(io: std.Io, lockPath: []const u8) !bool {
    var attempt: u32 = 0;
    while (attempt < LOCK_WAIT_ATTEMPTS) : (attempt += 1) {
        if (try tryTakeUpdateLock(io, lockPath)) {
            return true;
        }

        try sleep(io, updateBackoffMs(io, attempt));
    }

    return false;
}

//
// One pass of the body of updateFileRawOptimistic, run while the update lock is held (the `try` block
// in TypeScript). Returns true when the result was published.
//
fn updateFileRawAttempt(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, mutator: anytype) !bool {
    const fingerprintBefore = try fileFingerprint(io, filePath);
    const currentBytes = try readRawFileBytes(allocator, io, filePath);
    const updatedBytes = try mutator.run(allocator, currentBytes);

    const tempPath = try std.fmt.allocPrint(allocator, "{s}.tmp-{s}", .{ filePath, try randomUUID(allocator, io) });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tempPath, .data = updatedBytes });

    // If the file is unchanged since we read it, publish our version atomically.
    // Otherwise a writer that ignored the lock won; drop the temp and start over.
    const fingerprintAfter = try fileFingerprint(io, filePath);
    if (fingerprintsMatch(fingerprintBefore, fingerprintAfter)) {
        try renameIntoPlace(io, tempPath, filePath);
        return true;
    }
    try removeFileForce(io, tempPath);
    return false;
}

//
// Updates a file's raw bytes as a read-modify-write that is safe against other processes doing the
// same thing at the same time. It takes an exclusive lock beside the file, reads the current bytes
// (or passes `undefined` to the mutator when the file does not exist yet), applies `mutator`,
// writes the result to a temp file whose name carries a fresh UUID, and moves it into place. The
// lock is what makes concurrent updates lossless: without it two writers can both read the same
// contents and both publish, and whichever renames second silently discards the other's work.
//
// Holding the lock is not enough on its own, because a writer that does not take the lock can
// still change the file underneath us, so just before the atomic move it re-checks a cheap
// fingerprint (a stat, not a second full read) and retries from the fresh contents if the file
// moved on. `retries` bounds those conflicts only, not the wait for the lock, which is bounded
// separately: a slow write by one process is not a failure for the others, it is just their turn
// coming later. Waiting and retrying both back off with a randomized, growing delay, so writers
// that collide spread out instead of colliding again in lockstep.
//
// In Zig the mutator (TypeScript: `(current: Buffer | undefined) => Buffer`) is a value with a method
// `run(self, allocator, current: ?[]const u8) ![]const u8`.
//
pub fn updateFileRawOptimistic(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, mutator: anytype, retries: u32) !void {
    // The lock lives beside the file, so the directory has to exist before we can take it.
    try ensureFileDir(io, filePath);
    const lockPath = try std.fmt.allocPrint(allocator, "{s}.lock", .{filePath});

    var attempt: u32 = 0;
    while (attempt <= retries) : (attempt += 1) {
        if (!try takeUpdateLock(io, lockPath)) {
            return errors.throwError("Failed to update {s}: could not take the update lock after {d} attempts.", .{ filePath, LOCK_WAIT_ATTEMPTS });
        }

        const published = updateFileRawAttempt(allocator, io, filePath, mutator);

        // Released on the way out however we leave, so a failed mutator does not strand the
        // lock and make every other writer wait out the staleness timeout.
        try removeFileForce(io, lockPath);

        if (try published) {
            return;
        }

        // Back off before trying again so the writers that collided do not collide again.
        try sleep(io, updateBackoffMs(io, attempt));
    }
    return errors.throwError("Failed to update {s}: the file kept changing under concurrent writers after {d} retries.", .{ filePath, retries });
}

//
// The mutator updateFileOptimistic hands to updateFileRawOptimistic: it parses the current bytes,
// applies the caller's mutator and serializes the result (the arrow function in TypeScript).
//
fn OptimisticMutator(comptime ContentType: type, comptime MutatorT: type, comptime ParseT: type, comptime SerializeT: type) type {
    return struct {
        // The value to use when the file does not exist yet.
        fallback: ContentType,

        // The caller's mutator.
        mutator: MutatorT,

        // Parses the file's text.
        parse: ParseT,

        // Serializes the mutated value.
        serialize: SerializeT,

        //
        // Parses the current bytes (or uses the fallback), mutates and serializes them.
        //
        pub fn run(self: *const @This(), allocator: std.mem.Allocator, currentBytes: ?[]const u8) ![]const u8 {
            const current = if (currentBytes) |bytes| try self.parse.run(allocator, bytes) else self.fallback;
            return self.serialize.run(allocator, try self.mutator.run(allocator, current));
        }
    };
}

//
// Updates a file as an optimistic read-modify-write, with no cross-call locking or shared state.
// It reads and parses the current text (or uses `fallback` when absent), applies `mutator`, and
// publishes the serialized result through `updateFileRawOptimistic`, so a concurrent writer causes
// a reload and re-apply rather than a lost update. After `retries` such conflicts it throws.
//
// In Zig `mutator`, `parse` and `serialize` are values with a method `run(self, allocator, input)`:
// `mutator.run` takes and returns a ContentType, `parse.run` takes the text and returns a ContentType
// and `serialize.run` takes a ContentType and returns the text.
//
pub fn updateFileOptimistic(comptime ContentType: type, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, fallback: ContentType, mutator: anytype, parse: anytype, serialize: anytype, retries: u32) !void {
    const raw_mutator: OptimisticMutator(ContentType, @TypeOf(mutator), @TypeOf(parse), @TypeOf(serialize)) = .{
        .fallback = fallback,
        .mutator = mutator,
        .parse = parse,
        .serialize = serialize,
    };
    try updateFileRawOptimistic(allocator, io, filePath, &raw_mutator, retries);
}

// Not ported: updateToml, updateJson, emptyDir, copy (not used by replicate or verify).

//
// Synchronous version: Ensures that the directory exists.
//
pub fn ensureDirSync(io: std.Io, dirPath: []const u8) !void {
    return ensureDir(io, dirPath);
}

// Not ported: removeSync, copySync (not used by replicate or verify).

//
// Equivalent of Node's `os.tmpdir()`.
// On POSIX: TMPDIR, TMP or TEMP (without a trailing slash), else /tmp.
// On Windows: TEMP, TMP, else %SystemRoot%\temp (or %windir%\temp), without a trailing backslash unless the
// path is a drive root.
//
pub fn osTmpDir(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        var windowsPath: []const u8 = "";
        const windowsNames = [_][]const u8{ "TEMP", "TMP" };
        for (windowsNames) |name| {
            if (windowsPath.len == 0) {
                windowsPath = process_env.getEnv(name) orelse "";
            }
        }
        if (windowsPath.len == 0) {
            var systemRoot: []const u8 = process_env.getEnv("SystemRoot") orelse "";
            if (systemRoot.len == 0) {
                systemRoot = process_env.getEnv("windir") orelse "undefined";
            }
            windowsPath = try std.mem.concat(allocator, u8, &.{ systemRoot, "\\temp" });
        }
        if (windowsPath.len > 1 and std.mem.endsWith(u8, windowsPath, "\\") and !std.mem.endsWith(u8, windowsPath, ":\\")) {
            return windowsPath[0 .. windowsPath.len - 1];
        }
        return windowsPath;
    }
    const names = [_][]const u8{ "TMPDIR", "TMP", "TEMP" };
    for (names) |name| {
        if (process_env.getEnv(name)) |value| {
            if (value.len == 0) {
                continue;
            }
            if (value.len > 1 and value[value.len - 1] == '/') {
                return value[0 .. value.len - 1];
            }
            return value;
        }
    }
    return "/tmp";
}

//
// Returns the temp directory to use for this process, the system temp directory by default.
//
// PHOTOSPHERE_TMP_DIR overrides it, and names a directory Photosphere may use as it likes: the
// process temp goes in a "tmp" subdirectory of it, so whatever else lives at that path is left
// alone. Point it at a larger disk when the system temp directory is small, at a location with a
// different retention policy, or at a directory of your own so several Photosphere processes on one
// machine do not share scratch space.
//
// That last use is why the smoke tests set it: each test gets a directory of its own and passes it
// down, so the app writes inside the test's directory and no two tests can reach each other's files.
//
pub fn getProcessTmpDir(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    if (process_env.getEnv("PHOTOSPHERE_TMP_DIR")) |photosphereTmpDir| {
        if (photosphereTmpDir.len > 0) {
            const currentPath = try std.process.currentPathAlloc(io, allocator);
            return std.fs.path.resolve(allocator, &.{ currentPath, photosphereTmpDir, "tmp" });
        }
    }
    return osTmpDir(allocator);
}

//
// Equivalent of Node's `os.homedir()`: $HOME (%USERPROFILE% on Windows), or an empty string when it is not set.
//
fn osHomedir() []const u8 {
    const home_variable = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    return process_env.getEnv(home_variable) orelse "";
}

//
// Returns the directory Photosphere keeps its settings in: config.yaml and the databases list.
//
// The same Unix-style path on every desktop platform, Windows included, so one support answer covers
// every machine. PHOTOSPHERE_CONFIG_DIR overrides it, which is how a test run stays off the
// developer's real data.
//
// A device has no home directory, and the mobile `os` shim returns an empty string from homedir()
// precisely so derived paths stay inside the app's storage sandbox, so an empty home means the
// sandbox root.
//
// Rebuildable data does not belong here. See getCacheDir.
//
pub fn getConfigDir(allocator: std.mem.Allocator) ![]const u8 {
    if (process_env.getEnv("PHOTOSPHERE_CONFIG_DIR")) |configDir| {
        if (configDir.len > 0) {
            return configDir;
        }
    }
    const homeDir = osHomedir();
    if (homeDir.len > 0) {
        return std.fs.path.join(allocator, &.{ homeDir, ".config", "photosphere" });
    }
    return ".";
}

// Not ported: getCacheDir, readFileHead (not used by replicate or verify).
