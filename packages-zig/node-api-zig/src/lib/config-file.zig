const std = @import("std");
const node_utils = @import("node-utils-zig");
const config_format = @import("config-format.zig");
const fs = node_utils.fs;
const IConfigFile = config_format.IConfigFile;
const configFileToYaml = config_format.configFileToYaml;
const yamlToConfigFile = config_format.yamlToConfigFile;

//
// Reading and writing config.yaml where there is a filesystem: the CLI and the desktop app.
//
// The mobile apps read and write the same document through worker tasks instead (config.worker.ts),
// because a phone's WebView has no filesystem of its own. Both go through config-format.zig, so the
// file means the same thing whichever wrote it. The wiki page "Configuration-File" documents it for
// users.
//

//
// Returns the absolute path of the config file. PHOTOSPHERE_CONFIG_DIR moves it, which is how the
// smoke tests give each run its own settings and how two installations run side by side.
//
pub fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    return node_utils.path.join(allocator, &.{ try fs.getConfigDir(allocator), "config.yaml" });
}

//
// Loads the configuration from disk, returning the defaults when there is no file yet.
//
pub fn loadConfigFile(allocator: std.mem.Allocator, io: std.Io) !IConfigFile {
    const document = try fs.readYaml(allocator, io, try getConfigPath(allocator));
    return yamlToConfigFile(allocator, document);
}

// Not ported: saveConfigFile (it writes with writeYaml, which node-utils-zig does not port because the CLI does not
// reach it, and nothing but a test or a first write in the TypeScript uses it; the app goes through updateConfigFile).

//
// The mutator updateConfigFile hands to updateYaml (the arrow function in TypeScript): it turns the document into the
// configuration, lets the caller change it and turns it back into a document.
//
fn ConfigMutator(comptime MutatorT: type) type {
    return struct {
        // The caller's mutator.
        mutator: MutatorT,

        //
        // Applies the caller's mutator to the configuration the document holds.
        //
        pub fn run(self: *const @This(), allocator: std.mem.Allocator, document: std.json.Value) !std.json.Value {
            var config = try yamlToConfigFile(allocator, document);
            try self.mutator.run(allocator, &config);
            return configFileToYaml(allocator, config, null);
        }
    };
}

//
// Changes the configuration on disk. Every edit the app makes goes through here.
//
// The mutator is handed the file's CURRENT contents and changes them in place. updateYaml runs it
// under the update lock beside the file, checks the file has not moved before renaming, and re-runs
// the mutator against the new contents if it has, so two edits arriving together both survive.
//
// A load-then-save pair in its place would silently discard any edit made between the read and the
// write, and the window is not theoretical: a folder picker stays open for as long as the user takes
// to choose, so a config read before the dialog opened is stale by the time it closes.
//
// In Zig the mutator is a value with a method `run(self, allocator, config: *IConfigFile) !void`.
//
pub fn updateConfigFile(allocator: std.mem.Allocator, io: std.Io, mutator: anytype) !void {
    const configMutator: ConfigMutator(@TypeOf(mutator)) = .{
        .mutator = mutator,
    };
    try fs.updateYaml(allocator, io, try getConfigPath(allocator), .{
        .object = .empty,
    }, &configMutator, 3);
}

//
// The configuration a reader falls back to when there is no file. Re-exported so callers that only
// deal with the file do not have to reach into the format module for it.
//
pub const defaultConfigFile = config_format.defaultConfigFile;

// Not ported: config.worker.ts (the read-config and write-config tasks). Only the mobile worker registers them
// (mobile-worker-entry.ts), as it does state.worker.ts and databases-config.worker.ts, and the Zig task handlers
// (task-handlers.zig) carry only the tasks the CLI and the desktop app run.
