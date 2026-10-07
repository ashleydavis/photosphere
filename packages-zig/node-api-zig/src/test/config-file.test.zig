const std = @import("std");
const node_api = @import("node-api-zig");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const config_file = node_api.config_file;
const config_format = node_api.config_format;
const IConfigFile = config_format.IConfigFile;

//
// Points PHOTOSPHERE_CONFIG_DIR at a new empty directory and returns it.
//
fn freshConfigDir(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    _ = try test_environment.setupEnvironment(io);
    const dir = try temp_dirs.makeTempDir(allocator, io, name);
    const configDir = try std.fmt.allocPrint(allocator, "{s}/config", .{dir});
    try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", configDir);
    return configDir;
}

//
// Writes the config file in the config directory.
//
fn writeConfig(allocator: std.mem.Allocator, io: std.Io, configDir: []const u8, text: []const u8) !void {
    try test_files.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/config.yaml", .{configDir}), text);
}

//
// Reads the config file in the config directory.
//
fn readConfig(allocator: std.mem.Allocator, io: std.Io, configDir: []const u8) ![]const u8 {
    return test_files.readFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/config.yaml", .{configDir}));
}

test "getConfigPath is config.yaml in the config directory, joined and normalized as path.join does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "config-file-path");
    defer temp_dirs.removeTempDir(io, configDir);
    const unnormalized = try std.fmt.allocPrint(allocator, "{s}/./sub/..//", .{configDir});
    try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", unnormalized);

    const result = try config_file.getConfigPath(allocator);

    try std.testing.expectEqualStrings(try node_utils.path.join(allocator, &.{ configDir, "config.yaml" }), result);
    try std.testing.expect(std.mem.indexOf(u8, result, "..") == null);
    try std.testing.expect(std.mem.endsWith(u8, result, "config.yaml"));
}

test "loadConfigFile returns the defaults when the config file does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "config-file-missing");
    defer temp_dirs.removeTempDir(io, configDir);
    try std.Io.Dir.cwd().createDirPath(io, configDir);

    const config = try config_file.loadConfigFile(allocator, io);

    try std.testing.expect(!config.autoImport.settings.enabled);
    try std.testing.expect(!config.sync.settings.enabled);
    try std.testing.expect(config.sync.settings.onlyOnWifi);
    try std.testing.expect(config.theme == null);
    try std.testing.expect(!test_files.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/config.yaml", .{configDir})));
}

test "loadConfigFile returns the defaults for an empty config file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "config-file-empty");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "");

    const config = try config_file.loadConfigFile(allocator, io);

    try std.testing.expect(!config.autoImport.settings.enabled);
    try std.testing.expect(config.theme == null);
}

test "loadConfigFile reads the sections of the file and keeps a malformed section out of the way" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "config-file-sections");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir,
        \\theme: dark
        \\saved_searches:
        \\  - beach
        \\auto_import:
        \\  enabled: true
        \\  default_database_path: /photos
        \\  sources:
        \\    - type: folder
        \\      path: /home/me/Pictures
        \\      recurse: false
        \\sync: not-a-section
        \\
    );

    const config = try config_file.loadConfigFile(allocator, io);

    try std.testing.expectEqual(config_format.IConfigTheme.dark, config.theme.?);
    try std.testing.expectEqualStrings("beach", config.savedSearches.?[0]);
    try std.testing.expect(config.autoImport.settings.enabled);
    try std.testing.expectEqualStrings("/photos", config.autoImport.defaultDatabasePath.?);
    try std.testing.expectEqualStrings("/home/me/Pictures", config.autoImport.settings.sources[0].folder.path);
    try std.testing.expect(!config.autoImport.settings.sources[0].folder.recurse);
    try std.testing.expect(!config.sync.settings.enabled);
}

test "loadConfigFile throws when the config file is not YAML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "config-file-corrupt");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "sync:\n  enabled: true\n   bad indentation: [");

    try std.testing.expectError(error.Thrown, config_file.loadConfigFile(allocator, io));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "(") != null);
}

//
// A mutator for the updateConfigFile tests: records what it was handed and then changes the theme and developer mode,
// or throws when `fail` is set.
//
const RecordingMutator = struct {
    // Whether the mutator has run.
    ran: bool = false,

    // The theme the mutator was handed.
    seenTheme: ?config_format.IConfigTheme = null,

    // Whether the mutator was handed an auto import section that was switched on.
    seenAutoImportEnabled: bool = false,

    // The theme to store.
    theme: config_format.IConfigTheme = .light,

    // True to throw instead of changing the configuration.
    fail: bool = false,

    //
    // Records the configuration and changes it.
    //
    pub fn run(self: *RecordingMutator, allocator: std.mem.Allocator, config: *IConfigFile) !void {
        _ = allocator;
        self.ran = true;
        self.seenTheme = config.theme;
        self.seenAutoImportEnabled = config.autoImport.settings.enabled;
        if (self.fail) {
            return utils.errors.throwError("The mutator failed.", .{});
        }
        config.theme = self.theme;
        config.developerMode = true;
    }
};

test "updateConfigFile hands the mutator the file's current contents and writes what it changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "config-file-update");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir,
        \\theme: dark
        \\auto_import:
        \\  enabled: true
        \\  sources: []
        \\
    );
    var mutator: RecordingMutator = .{};

    try config_file.updateConfigFile(allocator, io, &mutator);

    try std.testing.expect(mutator.ran);
    try std.testing.expectEqual(config_format.IConfigTheme.dark, mutator.seenTheme.?);
    try std.testing.expect(mutator.seenAutoImportEnabled);
    try std.testing.expectEqualStrings(
        \\theme: light
        \\developer_mode: true
        \\auto_import:
        \\  enabled: true
        \\  pause_between_runs_ms: 30000
        \\  sources: []
        \\sync:
        \\  enabled: false
        \\  only_on_wifi: true
        \\  pause_between_runs_ms: 300000
        \\
    , try readConfig(allocator, io, configDir));
}

test "updateConfigFile creates the file from the defaults when there is none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "config-file-create");
    defer temp_dirs.removeTempDir(io, configDir);
    var mutator: RecordingMutator = .{
        .theme = .system,
    };

    try config_file.updateConfigFile(allocator, io, &mutator);

    try std.testing.expect(mutator.ran);
    try std.testing.expect(mutator.seenTheme == null);
    try std.testing.expect(!mutator.seenAutoImportEnabled);
    const config = try config_file.loadConfigFile(allocator, io);
    try std.testing.expectEqual(config_format.IConfigTheme.system, config.theme.?);
    try std.testing.expect(config.developerMode.?);
}

test "two updates in turn both survive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "config-file-two-updates");
    defer temp_dirs.removeTempDir(io, configDir);
    var first: RecordingMutator = .{
        .theme = .dark,
    };
    var second: RecordingMutator = .{
        .theme = .light,
    };

    try config_file.updateConfigFile(allocator, io, &first);
    try config_file.updateConfigFile(allocator, io, &second);

    // The second was handed what the first wrote.
    try std.testing.expectEqual(config_format.IConfigTheme.dark, second.seenTheme.?);
    const config = try config_file.loadConfigFile(allocator, io);
    try std.testing.expectEqual(config_format.IConfigTheme.light, config.theme.?);
}

// A mutator that throws is left to throw. The lock is released on the way out, and the caller gets its error rather
// than a half-applied change.
test "updateConfigFile leaves the file as it was when the mutator throws" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "config-file-update-throws");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "theme: dark\n");
    var mutator: RecordingMutator = .{
        .fail = true,
    };

    try std.testing.expectError(error.Thrown, config_file.updateConfigFile(allocator, io, &mutator));

    try std.testing.expectEqualStrings("The mutator failed.", utils.errors.lastErrorMessage());
    try std.testing.expectEqualStrings("theme: dark\n", try readConfig(allocator, io, configDir));
}

test "updateConfigFile throws when the file in place is not YAML, without running the mutator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "config-file-update-corrupt");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "sync:\n  enabled: true\n   bad indentation: [");
    var mutator: RecordingMutator = .{};

    try std.testing.expectError(error.Thrown, config_file.updateConfigFile(allocator, io, &mutator));

    try std.testing.expect(!mutator.ran);
}

test "defaultConfigFile is the format module's, with syncing and automatic import switched off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try config_file.defaultConfigFile(allocator);

    try std.testing.expect(!config.autoImport.settings.enabled);
    try std.testing.expect(!config.sync.settings.enabled);
}
