const std = @import("std");
const node_utils = @import("node-utils-zig");
const databases_config_format = @import("databases-config-format.zig");
const state_file = @import("state-file.zig");
const state_format = @import("state-format.zig");
const fs = node_utils.fs;
const IStateFile = state_format.IStateFile;
const tomlEntryToDatabaseEntry = databases_config_format.tomlEntryToDatabaseEntry;
const databaseEntryToToml = databases_config_format.databaseEntryToToml;
const errors = @import("utils-zig").errors;

// Re-exported: this module has always been where the codebase imports the entry type from. The
// definition now lives with the file format, which mobile shares.
pub const IDatabaseEntry = databases_config_format.IDatabaseEntry;

//
// Configuration for the databases list, stored in ~/.config/photosphere/databases.toml.
//
// Only the database records. Which databases were opened lately and which one to reopen is what
// the app remembered rather than what the user configured, so it is in the `databases` section of
// state.yaml, and the functions below that read or change it go there.
//
pub const IDatabasesConfig = struct {
    //
    // Structured list of configured databases.
    //
    databases: []const IDatabaseEntry,
};

//
// The file holding the list of databases, in the Photosphere data directory.
//
// getConfigDir works out where that is per platform: under the user's home directory on desktop and
// on the CLI, and the app's storage sandbox on a device, which has no home directory.
//
// Getting this wrong is not harmless. It previously always appended ".config/photosphere", so on a
// device the lookup resolved to a file that cannot exist, every credential lookup found an empty
// list, and S3 databases failed with "Region is missing" while working perfectly on desktop.
//
// (Zig: the environment is read on each call.)
//
fn DATABASES_FILE(allocator: std.mem.Allocator) ![]const u8 {
    return node_utils.path.join(allocator, &.{ try fs.getConfigDir(allocator), "databases.toml" });
}

//
// How many recently opened databases are remembered. Named once so the list that is trimmed and the
// list that is read back cannot disagree about the number.
//
pub const MAX_RECENT_DATABASES = 5;

//
// Gets an array property of a TOML object (null when it is absent or not an array).
//
fn arrayProperty(object: std.json.ObjectMap, key: []const u8) ?[]const std.json.Value {
    const value = object.get(key) orelse {
        return null;
    };
    return switch (value) {
        .array => |array| array.items,
        else => null,
    };
}

//
// Converts a TOML-shaped config object to an IDatabasesConfig.
//
pub fn tomlToDatabasesConfig(allocator: std.mem.Allocator, toml: std.json.ObjectMap) !IDatabasesConfig {
    var databases: std.ArrayList(IDatabaseEntry) = .empty;
    if (arrayProperty(toml, "databases")) |tomlDatabases| {
        for (tomlDatabases) |tomlEntry| {
            try databases.append(allocator, tomlEntryToDatabaseEntry(tomlEntry));
        }
    }
    return .{
        .databases = databases.items,
    };
}

//
// Converts an IDatabasesConfig to the TOML on-disk layout.
//
pub fn databasesConfigToToml(allocator: std.mem.Allocator, config: IDatabasesConfig) !std.json.Value {
    var tomlDatabases: std.json.Array = .init(allocator);
    for (config.databases) |entry| {
        try tomlDatabases.append(try databaseEntryToToml(allocator, entry));
    }
    var toml: std.json.ObjectMap = .empty;
    try toml.put(allocator, "databases", .{
        .array = tomlDatabases,
    });
    return .{
        .object = toml,
    };
}

//
// Returns true if the two names match case-insensitively.
// (Zig: ASCII letters only, as in
// fuzzy-match-zig.)
//
pub fn namesMatch(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

//
// Loads the databases configuration from disk.
// Returns a default config with an empty list if the file does not exist.
//
pub fn loadDatabasesConfig(allocator: std.mem.Allocator, io: std.Io) !IDatabasesConfig {
    const databasesFile = try DATABASES_FILE(allocator);
    if (!fs.pathExists(io, databasesFile)) {
        return .{
            .databases = &.{},
        };
    }

    const tomlValue = try fs.readToml(allocator, io, databasesFile);
    const toml = switch (tomlValue) {
        .object => |object| object,
        else => std.json.ObjectMap.empty,
    };
    return tomlToDatabasesConfig(allocator, toml);
}

//
// Changes the databases configuration on disk. Every edit in this module goes through here.
//
// The mutator is handed the file's CURRENT contents and returns the new ones. updateToml runs it
// under the update lock beside the file, checks the file has not moved before renaming, and re-runs
// the mutator against the new contents if it has. So two edits arriving together both survive: the
// second is applied on top of the first rather than overwriting it.
//
// This replaced a saveDatabasesConfig that took a whole config and wrote it. Every caller was
// load-then-save, so two overlapping edits meant the later write silently discarded the earlier
// one's change, with nothing to show for it. Several processes write this one file: the desktop
// shell, the REST API and MCP utility processes, and the worker pool.
//
// Windows is where that stopped being silent. It refuses to rename over a file another handle still
// holds, so the overlapping renames surfaced as "EPERM: operation not permitted, rename ...
// databases.toml", failing one to six of the thirty three desktop smoke tests per run. Taking turns
// fixes the visible failure on Windows and the invisible one everywhere else.
//
// A mutator that throws is left to throw. The lock is released on the way out, and the caller gets
// its error rather than a half-applied change.
//
// In Zig the mutator is a value with a method `run(self, allocator, config: IDatabasesConfig) !IDatabasesConfig`.
//
pub fn updateDatabasesConfig(allocator: std.mem.Allocator, io: std.Io, mutate: anytype) !void {
    var emptyConfig: std.json.ObjectMap = .empty;
    try emptyConfig.put(allocator, "databases", .{
        .array = .init(allocator),
    });
    const tomlMutator: DatabasesConfigTomlMutator(@TypeOf(mutate)) = .{
        .mutate = mutate,
    };
    try fs.updateToml(allocator, io, try DATABASES_FILE(allocator), .{
        .object = emptyConfig,
    }, &tomlMutator, 3);
}

//
// The mutator updateDatabasesConfig hands to updateToml: converts the TOML to a config, applies the caller's
// mutator and converts the result back.
//
fn DatabasesConfigTomlMutator(comptime MutateType: type) type {
    return struct {
        // The caller's mutator.
        mutate: MutateType,

        //
        // Converts, mutates and converts back.
        //
        pub fn run(self: *const @This(), allocator: std.mem.Allocator, currentToml: std.json.Value) !std.json.Value {
            const tomlObject = switch (currentToml) {
                .object => |object| object,
                else => std.json.ObjectMap.empty,
            };
            const updated = try self.mutate.run(allocator, try tomlToDatabasesConfig(allocator, tomlObject));
            return databasesConfigToToml(allocator, updated);
        }
    };
}

//
// Returns all configured database entries.
//
pub fn getDatabases(allocator: std.mem.Allocator, io: std.Io) ![]const IDatabaseEntry {
    const config = try loadDatabasesConfig(allocator, io);
    return config.databases;
}

//
// Finds a database entry by name using case-insensitive matching.
// Returns the first match if any. Returns undefined if no entry matches.
//
pub fn findDatabase(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !?IDatabaseEntry {
    const config = try loadDatabasesConfig(allocator, io);
    for (config.databases) |dbEntry| {
        if (namesMatch(dbEntry.name, name)) {
            return dbEntry;
        }
    }
    return null;
}

//
// The mutator of addDatabaseEntry.
//
const AddDatabaseEntryMutator = struct {
    // The entry to add.
    entry: IDatabaseEntry,

    //
    // Appends the entry, throwing when its name is taken.
    //
    pub fn run(self: *const AddDatabaseEntryMutator, allocator: std.mem.Allocator, config: IDatabasesConfig) !IDatabasesConfig {
        for (config.databases) |dbEntry| {
            if (namesMatch(dbEntry.name, self.entry.name)) {
                return errors.throwError("A database named \"{s}\" already exists.", .{self.entry.name});
            }
        }
        var databases: std.ArrayList(IDatabaseEntry) = .empty;
        try databases.appendSlice(allocator, config.databases);
        try databases.append(allocator, self.entry);
        var updated = config;
        updated.databases = databases.items;
        return updated;
    }
};

//
// Adds a new database entry to the list.
// Throws if an entry with the same name (case-insensitive) already exists; this acts as
// a storage-layer invariant in addition to any UX checks.
//
pub fn addDatabaseEntry(allocator: std.mem.Allocator, io: std.Io, entry: IDatabaseEntry) !void {
    const mutator: AddDatabaseEntryMutator = .{
        .entry = entry,
    };
    try updateDatabasesConfig(allocator, io, &mutator);
}

//
// The mutator of updateDatabaseEntry.
//
const UpdateDatabaseEntryMutator = struct {
    // The name of the entry to update.
    originalName: []const u8,

    // The new fields of the entry.
    entry: IDatabaseEntry,

    //
    // Replaces the entry.
    //
    pub fn run(self: *const UpdateDatabaseEntryMutator, allocator: std.mem.Allocator, config: IDatabasesConfig) !IDatabasesConfig {
        var matchIndex: ?usize = null;
        for (config.databases, 0..) |dbEntry, dbIndex| {
            if (namesMatch(dbEntry.name, self.originalName)) {
                matchIndex = dbIndex;
                break;
            }
        }
        const foundIndex = matchIndex orelse {
            return errors.throwError("No database named \"{s}\" found.", .{self.originalName});
        };
        const renamed = !namesMatch(self.entry.name, self.originalName);
        if (renamed) {
            for (config.databases, 0..) |dbEntry, dbIndex| {
                if (dbIndex != foundIndex and namesMatch(dbEntry.name, self.entry.name)) {
                    return errors.throwError("A database named \"{s}\" already exists.", .{self.entry.name});
                }
            }
        }
        const updatedDatabases = try allocator.dupe(IDatabaseEntry, config.databases);
        updatedDatabases[foundIndex] = self.entry;
        var updated = config;
        updated.databases = updatedDatabases;
        return updated;
    }
};

//
// The state.yaml mutator of updateDatabaseEntry's rename: points the recents slot of the old name
// at the new one.
//
const RenameRecentDatabaseMutator = struct {
    // The name the database had.
    originalName: []const u8,

    // The name it has now.
    newName: []const u8,

    //
    // Rewrites every recents slot holding the old name.
    //
    pub fn run(self: *const RenameRecentDatabaseMutator, allocator: std.mem.Allocator, state: *IStateFile) !void {
        const recentNames = try allocator.alloc([]const u8, state.databases.recentNames.len);
        for (state.databases.recentNames, 0..) |recentName, recentIndex| {
            recentNames[recentIndex] = if (namesMatch(recentName, self.originalName)) self.newName else recentName;
        }
        state.databases.recentNames = recentNames;
    }
};

//
// Updates the entry currently identified by `originalName` with the new fields in `entry`.
// If the new entry's name differs from `originalName`, the matching slot in the recents in
// state.yaml is rewritten to keep the recents list pointing at the same entry.
// Throws if the rename would collide with another existing entry, or if no entry with
// `originalName` is found.
//
// databases.toml is changed first and state.yaml second, each under its own lock. The recents are
// read against the records in databases.toml, so a slot still holding the old name after the first
// write is dropped when the recents are read rather than pointing at the wrong database.
//
pub fn updateDatabaseEntry(allocator: std.mem.Allocator, io: std.Io, originalName: []const u8, entry: IDatabaseEntry) !void {
    const mutator: UpdateDatabaseEntryMutator = .{
        .originalName = originalName,
        .entry = entry,
    };
    try updateDatabasesConfig(allocator, io, &mutator);
    if (!namesMatch(entry.name, originalName)) {
        const renameMutator: RenameRecentDatabaseMutator = .{
            .originalName = originalName,
            .newName = entry.name,
        };
        try state_file.updateStateFile(allocator, io, &renameMutator);
    }
}

//
// The mutator of removeDatabaseEntry.
//
const RemoveDatabaseEntryMutator = struct {
    // The name of the entry to remove.
    name: []const u8,

    //
    // Removes the first matching entry.
    //
    pub fn run(self: *const RemoveDatabaseEntryMutator, allocator: std.mem.Allocator, config: IDatabasesConfig) !IDatabasesConfig {
        var matchIndex: ?usize = null;
        for (config.databases, 0..) |dbEntry, dbIndex| {
            if (namesMatch(dbEntry.name, self.name)) {
                matchIndex = dbIndex;
                break;
            }
        }
        const foundIndex = matchIndex orelse {
            return config;
        };
        var updatedDatabases: std.ArrayList(IDatabaseEntry) = .empty;
        try updatedDatabases.appendSlice(allocator, config.databases);
        _ = updatedDatabases.orderedRemove(foundIndex);
        var updated = config;
        updated.databases = updatedDatabases.items;
        return updated;
    }
};

//
// Removes a database entry by name (case-insensitive).
// Removes only the first matching entry from `databases` (defensive against legacy state
// where two entries share a name). Also removes the same name from the recents in state.yaml.
// No-op if no entry matches.
//
// The recents are cleaned whether or not the entry is there, in case of stale state naming an
// entry that has already gone. databases.toml is changed first, so a name still in the recents
// after the first write has no record and is dropped when the recents are read.
//
pub fn removeDatabaseEntry(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    const mutator: RemoveDatabaseEntryMutator = .{
        .name = name,
    };
    try updateDatabasesConfig(allocator, io, &mutator);
    try removeRecentDatabaseName(allocator, io, name);
}

//
// Returns the recently opened database names as state.yaml holds them, most recent first, including
// any that no longer have a record in databases.toml.
//
pub fn getRecentDatabaseNames(allocator: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    const state = try state_file.loadStateFile(allocator, io);
    return state.databases.recentNames;
}

//
// Returns the most recently opened databases, ordered most-recent first, at most
// MAX_RECENT_DATABASES of them.
// Names that no longer resolve to an entry in the databases list are silently dropped.
//
pub fn getRecentDatabases(allocator: std.mem.Allocator, io: std.Io) ![]const IDatabaseEntry {
    const config = try loadDatabasesConfig(allocator, io);
    const recentNames = try getRecentDatabaseNames(allocator, io);
    var result: std.ArrayList(IDatabaseEntry) = .empty;
    for (recentNames) |recentName| {
        if (result.items.len >= MAX_RECENT_DATABASES) {
            break;
        }
        var found: ?IDatabaseEntry = null;
        for (config.databases) |dbEntry| {
            if (namesMatch(dbEntry.name, recentName)) {
                found = dbEntry;
                break;
            }
        }
        if (found) |foundEntry| {
            try result.append(allocator, foundEntry);
        }
    }
    return result.items;
}

//
// The mutator of removeRecentDatabaseName.
//
const RemoveRecentDatabaseNameMutator = struct {
    // The name to remove from the recents.
    name: []const u8,

    //
    // Drops the name from the recents and leaves everything else as it was.
    //
    pub fn run(self: *const RemoveRecentDatabaseNameMutator, allocator: std.mem.Allocator, state: *IStateFile) !void {
        var recentNames: std.ArrayList([]const u8) = .empty;
        for (state.databases.recentNames) |recentName| {
            if (!namesMatch(recentName, self.name)) {
                try recentNames.append(allocator, recentName);
            }
        }
        state.databases.recentNames = recentNames.items;
    }
};

//
// Removes the given name from the recents in state.yaml only. Leaves the matching entry
// in `databases` untouched. No-op if the name is not in the recent list.
//
pub fn removeRecentDatabaseName(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    const mutator: RemoveRecentDatabaseNameMutator = .{
        .name = name,
    };
    try state_file.updateStateFile(allocator, io, &mutator);
}

//
// The mutator of markDatabaseOpened.
//
const MarkDatabaseOpenedMutator = struct {
    // The name of the database that was opened, as its record in databases.toml spells it.
    name: []const u8,

    //
    // Puts the name first in the recents, trimming the list.
    //
    pub fn run(self: *const MarkDatabaseOpenedMutator, allocator: std.mem.Allocator, state: *IStateFile) !void {
        var recentNames: std.ArrayList([]const u8) = .empty;
        try recentNames.append(allocator, self.name);
        for (state.databases.recentNames) |recentName| {
            if (!namesMatch(recentName, self.name)) {
                try recentNames.append(allocator, recentName);
            }
        }
        state.databases.recentNames = recentNames.items[0..@min(recentNames.items.len, MAX_RECENT_DATABASES)];
    }
};

//
// Moves the database entry matching the given name (case-insensitive) to the front of
// the recents in state.yaml, trimming the list to MAX_RECENT_DATABASES entries.
// No-op if no entry matches.
//
pub fn markDatabaseOpened(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    const foundEntry = try findDatabase(allocator, io, name) orelse {
        return;
    };
    const mutator: MarkDatabaseOpenedMutator = .{
        .name = foundEntry.name,
    };
    try state_file.updateStateFile(allocator, io, &mutator);
}

//
// Returns the path of the database to reopen on the next launch, or null when none is open.
//
pub fn getLastDatabase(allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    const state = try state_file.loadStateFile(allocator, io);
    return state.databases.lastOpenedPath;
}

//
// The mutator of setLastDatabase.
//
const SetLastDatabaseMutator = struct {
    // The database to reopen on the next launch, or null to clear it.
    databasePath: ?[]const u8,

    //
    // Replaces the last database and carries everything else through.
    //
    pub fn run(self: *const SetLastDatabaseMutator, allocator: std.mem.Allocator, state: *IStateFile) !void {
        _ = allocator;
        state.databases.lastOpenedPath = self.databasePath;
    }
};

//
// Records the database to reopen on the next launch in state.yaml. null clears it, which is what
// closing a database does.
//
// Written through updateStateFile like every other edit of that file, so the rest of the state is
// carried through untouched rather than being rewritten from a copy read earlier.
//
pub fn setLastDatabase(allocator: std.mem.Allocator, io: std.Io, databasePath: ?[]const u8) !void {
    const mutator: SetLastDatabaseMutator = .{
        .databasePath = databasePath,
    };
    try state_file.updateStateFile(allocator, io, &mutator);
}
