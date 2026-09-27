const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const prompts = @import("../lib/clack/prompts.zig");
const log = &utils.log.log;
const exit = node_utils.termination.exit;
const createDatabase = init_cmd.createDatabase;
const ICreateCommandOptions = init_cmd.ICreateCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const intro = prompts.intro;

//
// Options of the init command (TypeScript: IInitCommandOptions extends ICreateCommandOptions).
//
pub const IInitCommandOptions = ICreateCommandOptions;

//
// Formats a message into the allocator (TypeScript: a template literal).
//
fn text(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(allocator, fmt, args);
}

//
// Command that initializes a new Photosphere media file database.
//
pub fn initCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IInitCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;

    try intro(io, try pc.blue(allocator, "Creating a new media file database..."), .{});

    const databaseDir = (try createDatabase(allocator, io, options.base.db, options, uuidGenerator, timestampProvider, sessionId)).databaseDir;

    const isCurrentDir = std.mem.eql(u8, databaseDir, ".") or std.mem.eql(u8, databaseDir, "./");
    const displayPath = if (isCurrentDir) "the current directory" else databaseDir;

    log.info("");
    log.info(try pc.green(allocator, try text(allocator, "\u{2713}  Created new media file database in {s}", .{displayPath})));
    log.info(try pc.yellow(allocator, "\u{26A0}\u{FE0F} Important: Never modify database files manually - always use the psi tool!"));

    const hasKey = options.base.key != null and options.base.key.?.len > 0;
    if ((options.generateKey orelse false) and hasKey) {
        log.info("");
        log.info(try pc.green(allocator, try text(allocator, "\u{2713}  Encryption key \"{s}\" stored.", .{options.base.key.?})));
        log.info(try pc.yellow(allocator, "\u{26A0}\u{FE0F} Keep this key safe! You will need it to access your encrypted database."));
    }

    log.info("");
    log.info("");
    log.info(try pc.bold(allocator, "Add media files:"));
    if (isCurrentDir) {
        log.info(try text(allocator, "    {s}", .{try pc.cyan(allocator, "psi add <file or directory>")}));
    }
    else {
        log.info(try text(allocator, "    {s}", .{try pc.cyan(allocator, try text(allocator, "cd {s}", .{databaseDir}))}));
        log.info(try text(allocator, "    {s}", .{try pc.cyan(allocator, "psi add <file or directory>")}));
    }
    log.info("");
    if (!isCurrentDir) {
        log.info("Or specify the path:");
        log.info(try text(allocator, "    {s}", .{try pc.cyan(allocator, try text(allocator, "psi add --db {s} <file or directory>", .{databaseDir}))}));
    }

    if (hasKey) {
        log.info("");
        log.info("When using your encrypted database, specify the key name:");
        log.info(try text(allocator, "    {s}", .{try pc.cyan(allocator, try text(allocator, "psi add --key {s} <file or directory>", .{options.base.key.?}))}));
    }

    // Show follow-up commands
    log.info("");
    log.info(try pc.bold(allocator, "Examples:"));
    const dbFlag = if (isCurrentDir) "" else try text(allocator, " --db {s}", .{databaseDir});
    const keyFlag = if (hasKey) try text(allocator, " --key {s}", .{options.base.key.?}) else "";
    const flags = try text(allocator, "{s}{s}", .{ dbFlag, keyFlag });
    log.info(try text(allocator, "    {s}   - Adds a single photo to the database", .{try pc.cyan(allocator, try text(allocator, "psi add{s} photo.jpg", .{flags}))}));
    log.info(try text(allocator, "    {s}   - Adds a single video to the database", .{try pc.cyan(allocator, try text(allocator, "psi add{s} video.mp4", .{flags}))}));
    log.info(try text(allocator, "    {s}  - Adds all media files in a directory", .{try pc.cyan(allocator, try text(allocator, "psi add{s} directory/", .{flags}))}));
    log.info("");

    exit(io, 0);
}
