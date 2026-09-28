//
// Port of apps/cli/src/examples.ts: the usage examples shown in the help of the commands.
//

const std = @import("std");
const commander = @import("lib/commander.zig");

//
// A usage example of a command.
//
pub const ICommandExample = struct {
    // The command line.
    command: []const u8,

    // What the command line does.
    description: []const u8,
};

//
// The examples of a command, by command name.
//
pub const ICommandExamples = struct {
    // The name of the command.
    commandName: []const u8,

    // Its examples.
    examples: []const ICommandExample,
};

//
// Centralized examples for all CLI commands
// (only the commands implemented in Zig are ported: init, add, consolidate, info, tools, summary, verify, repair, replicate,
// compare, version, export, list, upgrade, hash, encrypt, decrypt, sync, remove, find-orphans and remove-orphans).
//
pub const COMMAND_EXAMPLES = [_]ICommandExamples{
    .{
        .commandName = "init",
        .examples = &.{
            .{
                .command = "psi init --db .",
                .description = "Creates a database in current directory.",
            },
            .{
                .command = "psi init --db ./photos",
                .description = "Creates a database in ./photos directory.",
            },
        },
    },
    .{
        .commandName = "add",
        .examples = &.{
            .{
                .command = "psi add --db ./photos ~/Pictures",
                .description = "Adds all files from ~/Pictures to the database.",
            },
            .{
                .command = "psi add --db ./photos image.jpg video.mp4",
                .description = "Adds specific files to the database.",
            },
            .{
                .command = "psi add --db ./photos ~/Downloads/photos",
                .description = "Adds a directory recursively.",
            },
        },
    },
    .{
        .commandName = "consolidate",
        .examples = &.{
            .{
                .command = "psi consolidate --db ./photos ./backup",
                .description = "Creates the remote as a copy of this database when nothing is there.",
            },
            .{
                .command = "psi consolidate --db ./photos s3:my-bucket/photos",
                .description = "Joins an S3 remote that already holds a different database, so the two can sync.",
            },
            .{
                .command = "psi consolidate --db ./photos ./shared",
                .description = "Records an already-related remote as this database's origin.",
            },
        },
    },
    .{
        .commandName = "info",
        .examples = &.{
            .{
                .command = "psi info photo.jpg",
                .description = "Shows detailed information about a photo.",
            },
            .{
                .command = "psi info photo1.jpg photo2.jpg",
                .description = "Analyzes multiple specific files.",
            },
            .{
                .command = "psi info ~/Pictures",
                .description = "Analyzes all media files in a directory.",
            },
            .{
                .command = "psi info --db ./photos <asset-id>",
                .description = "Shows database metadata for an asset by ID.",
            },
            .{
                .command = "psi info --db ./photos <hash>",
                .description = "Shows database metadata for asset(s) with the given hash.",
            },
        },
    },
    .{
        .commandName = "tools",
        .examples = &.{
            .{
                .command = "psi tools",
                .description = "Checks the status of all required media processing tools.",
            },
        },
    },
    .{
        .commandName = "summary",
        .examples = &.{
            .{
                .command = "psi summary --db .",
                .description = "Shows a summary for the database in current directory.",
            },
            .{
                .command = "psi summary --db ./photos",
                .description = "Shows summary for the database in the ./photos directory.",
            },
        },
    },
    .{
        .commandName = "verify",
        .examples = &.{
            .{
                .command = "psi verify --db .",
                .description = "Verifies a database in the current directory.",
            },
            .{
                .command = "psi verify --db ./photos",
                .description = "Verifies a database in the ./photos directory.",
            },
            .{
                .command = "psi verify --db ./photos --full",
                .description = "Forces full verification of all files.",
            },
        },
    },
    .{
        .commandName = "repair",
        .examples = &.{
            .{
                .command = "psi repair --db ./photos --source ./backup",
                .description = "Repairs corrupted files from a backup database.",
            },
            .{
                .command = "psi repair --db . --source ./backup --full",
                .description = "Forces full repair verification of all files.",
            },
        },
    },
    .{
        .commandName = "replicate",
        .examples = &.{
            .{
                .command = "psi replicate --db ./photos --dest ./backup",
                .description = "Replicates a database to a backup location.",
            },
            .{
                .command = "psi replicate --db . --dest s3:bucket/photos",
                .description = "Replicates the current database to S3.",
            },
        },
    },
    .{
        .commandName = "compare",
        .examples = &.{
            .{
                .command = "psi compare --db ./photos --dest ./backup",
                .description = "Compares an original database with a backup.",
            },
            .{
                .command = "psi compare --db . --dest s3:bucket/photos",
                .description = "Compares a local database with an S3 replica.",
            },
            .{
                .command = "psi compare --db ./photos --dest ./backup --full",
                .description = "Shows all differences without truncation.",
            },
            .{
                .command = "psi compare --db ./photos --dest ./backup --max 20",
                .description = "Shows up to 20 items in each category.",
            },
        },
    },
    .{
        .commandName = "version",
        .examples = &.{
            .{
                .command = "psi version",
                .description = "Shows version information for psi and its dependencies.",
            },
        },
    },
    .{
        .commandName = "export",
        .examples = &.{
            .{
                .command = "psi export --db ./photos a1b2c3d4-e5f6-7890-abcd-ef1234567890 ./exported-photo.jpg",
                .description = "Exports original asset with ID to a specific file.",
            },
            .{
                .command = "psi export --db ./photos f1e2d3c4-b5a6-7890-cdef-ab1234567890 ./exports/",
                .description = "Exports original asset to a directory (keeps original name).",
            },
            .{
                .command = "psi export --db . 12345678-9abc-def0-1234-567890abcdef ~/Downloads/my-photo.jpg --type display",
                .description = "Exports display version of asset.",
            },
            .{
                .command = "psi export --db ./photos a1b2c3d4-e5f6-7890-abcd-ef1234567890 ./thumbs/ --type thumb",
                .description = "Exports thumbnail version to directory.",
            },
        },
    },
    .{
        .commandName = "list",
        .examples = &.{
            .{
                .command = "psi list --db .",
                .description = "Lists all files in the current directory database.",
            },
            .{
                .command = "psi list --db ./photos",
                .description = "Lists all files in the ./photos database.",
            },
            .{
                .command = "psi list --db ./photos --page-size 10",
                .description = "Lists files with 10 files per page.",
            },
        },
    },
    .{
        .commandName = "find-orphans",
        .examples = &.{
            .{
                .command = "psi find-orphans --db .",
                .description = "Finds orphaned files in the current directory database.",
            },
            .{
                .command = "psi find-orphans --db ./photos",
                .description = "Finds orphaned files in the ./photos database.",
            },
        },
    },
    .{
        .commandName = "remove-orphans",
        .examples = &.{
            .{
                .command = "psi remove-orphans --db .",
                .description = "Removes orphaned files from the current directory database.",
            },
            .{
                .command = "psi remove-orphans --db ./photos",
                .description = "Removes orphaned files from the ./photos database.",
            },
            .{
                .command = "psi remove-orphans --db ./photos --yes",
                .description = "Removes orphaned files without confirmation prompt.",
            },
        },
    },
    .{
        .commandName = "upgrade",
        .examples = &.{
            .{
                .command = "psi upgrade --db .",
                .description = "Upgrades the database in current directory to latest version.",
            },
            .{
                .command = "psi upgrade --db ./photos",
                .description = "Upgrades the database in ./photos directory.",
            },
        },
    },
    .{
        .commandName = "hash",
        .examples = &.{
            .{
                .command = "psi hash photo.jpg",
                .description = "Computes hash of a local file using the same algorithm as the database.",
            },
            .{
                .command = "psi hash s3://my-bucket/photo.jpg",
                .description = "Computes hash of file stored in S3.",
            },
            .{
                .command = "psi hash fs:/path/to/photo.jpg",
                .description = "Computes hash with explicit filesystem prefix.",
            },
            .{
                .command = "psi hash --key ./key encrypted:photo.jpg",
                .description = "Computes hash of an encrypted file.",
            },
        },
    },
    .{
        .commandName = "encrypt",
        .examples = &.{
            .{
                .command = "psi encrypt --db ./photos --key my-photos.key --yes",
                .description = "Encrypts a plain database in place using the specified key.",
            },
            .{
                .command = "psi encrypt --db ./photos --key new.key,old.key --yes",
                .description = "Re-encrypts in place using the first key for new writes and the full list for reads.",
            },
        },
    },
    .{
        .commandName = "decrypt",
        .examples = &.{
            .{
                .command = "psi decrypt --db ./photos --key my-photos.key --yes",
                .description = "Decrypts the encrypted database in place.",
            },
        },
    },
    .{
        .commandName = "sync",
        .examples = &.{
            .{
                .command = "psi sync --db ./photos --dest ./backup",
                .description = "Synchronizes changes between two databases.",
            },
            .{
                .command = "psi sync --db . --dest s3:bucket/photos",
                .description = "Synchronizes local database with an S3 replica.",
            },
        },
    },
    .{
        .commandName = "remove",
        .examples = &.{
            .{
                .command = "psi remove --db ./photos a1b2c3d4-e5f6-7890-abcd-ef1234567890",
                .description = "Removes asset with ID from the database.",
            },
            .{
                .command = "psi remove --db . f1e2d3c4-b5a6-7890-cdef-ab1234567890",
                .description = "Removes asset from current directory database.",
            },
        },
    },
};

// Not ported: MAIN_EXAMPLES (the program help is shown by the TypeScript CLI).

//
// Helper function to format examples for help text
//
pub fn formatExamplesForHelp(allocator: std.mem.Allocator, examples: []const ICommandExample) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    for (examples) |example| {
        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(allocator, "  ");
        try line.appendSlice(allocator, example.command);
        const length = commander.jsLength(example.command);
        if (length < 32) {
            try line.appendNTimes(allocator, ' ', 32 - length);
        }
        try line.append(allocator, ' ');
        try line.appendSlice(allocator, example.description);
        try lines.append(allocator, line.items);
    }
    return std.mem.join(allocator, "\n", lines.items);
}

//
// Helper function to get examples help text for a command
//
pub fn getCommandExamplesHelp(allocator: std.mem.Allocator, commandName: []const u8) ![]const u8 {
    for (COMMAND_EXAMPLES) |entry| {
        if (std.mem.eql(u8, entry.commandName, commandName)) {
            if (entry.examples.len == 0) {
                return "";
            }
            return std.fmt.allocPrint(allocator, "\nExamples:\n{s}", .{try formatExamplesForHelp(allocator, entry.examples)});
        }
    }
    return "";
}
