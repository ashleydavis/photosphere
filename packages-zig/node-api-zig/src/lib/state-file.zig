const std = @import("std");
const node_utils = @import("node-utils-zig");
const state_format = @import("state-format.zig");
const fs = node_utils.fs;
const IStateFile = state_format.IStateFile;
const stateFileToYaml = state_format.stateFileToYaml;
const yamlToStateFile = state_format.yamlToStateFile;

//
// Reading and writing state.yaml where there is a filesystem: the CLI and the desktop app.
//
// The sibling of config-file.ts, and it works the same way. The mobile apps read and write the same
// document through worker tasks instead (state.worker.ts), because a phone's WebView has no
// filesystem of its own. Both go through state-format.ts, so the file means the same thing whichever
// wrote it.
//
// Unlike config.yaml this file is not documented for users. Nothing in it was chosen by anyone: it is
// what the app remembered so the interface comes back the way it was left.
//

//
// Returns the absolute path of the state file. PHOTOSPHERE_CONFIG_DIR moves it, along with
// config.yaml and databases.toml, which is how the smoke tests give each run its own settings and how
// two installations run side by side.
//
pub fn getStatePath(allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ try fs.getConfigDir(allocator), "state.yaml" });
}

//
// Loads the state from disk, returning the defaults when there is no file yet.
//
pub fn loadStateFile(allocator: std.mem.Allocator, io: std.Io) !IStateFile {
    const document = try fs.readYaml(allocator, io, try getStatePath(allocator));
    return yamlToStateFile(allocator, document);
}

//
// The mutator updateStateFile hands to updateYaml (the arrow function in TypeScript): it turns the
// document into the state, lets the caller change it and turns it back into a document.
//
fn StateMutator(comptime MutatorT: type) type {
    return struct {
        // The caller's mutator.
        mutator: MutatorT,

        //
        // Applies the caller's mutator to the state the document holds.
        //
        pub fn run(self: *const @This(), allocator: std.mem.Allocator, document: std.json.Value) !std.json.Value {
            var state = try yamlToStateFile(allocator, document);
            try self.mutator.run(allocator, &state);
            return stateFileToYaml(allocator, state);
        }
    };
}

//
// Changes the state on disk. Every edit goes through here.
//
// The mutator is handed the file's CURRENT contents and changes them in place. updateYaml runs it
// under the update lock beside the file, checks the file has not moved before renaming, and re-runs
// the mutator against the new contents if it has, so two edits arriving together both survive.
//
// In Zig the mutator is a value with a method `run(self, allocator, state: *IStateFile) !void`.
//
pub fn updateStateFile(allocator: std.mem.Allocator, io: std.Io, mutator: anytype) !void {
    const stateMutator: StateMutator(@TypeOf(mutator)) = .{ .mutator = mutator };
    try fs.updateYaml(allocator, io, try getStatePath(allocator), .{ .object = .empty }, &stateMutator, 3);
}
