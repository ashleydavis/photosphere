const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const tools = @import("tools-zig");
const pc = @import("picocolors.zig");
const prompts = @import("clack/prompts.zig");
const installation_instructions = @import("installation-instructions.zig");
const verifyTools = tools.verifyTools;
const exit = node_utils.termination.exit;
const log = &utils.log.log;
const confirm = prompts.confirm;
const isCancel = prompts.isCancel;
const showInstallationInstructions = installation_instructions.showInstallationInstructions;

//
// Ensures tools are available for commands that need media processing.
// Shows user-friendly error and exits if tools are missing.
//
pub fn ensureMediaProcessingTools(allocator: std.mem.Allocator, io: std.Io, nonInteractive: bool) !void {
    const toolsStatus = try verifyTools(allocator, io);

    if (toolsStatus.allAvailable) {
        return; // All tools are available, continue
    }

    // Tools are missing, show error and ask for installation instructions
    log.@"error"(try pc.red(allocator, "\u{274C} Required media processing tools are not available."));
    log.info("");

    const missingTools = toolsStatus.missingTools;
    log.info(try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "Missing tools: {s}", .{try std.mem.join(allocator, ", ", missingTools)})));
    log.info("");

    // Ask if user wants to see installation instructions (or show them automatically in non-interactive mode)
    var showInstructions = true;
    if (!nonInteractive) {
        const userChoice = try confirm(allocator, io, .{
            .message = "Would you like to see installation instructions?",
            .initialValue = true,
        });

        if (isCancel(userChoice)) {
            log.info("");
            log.info(try pc.blue(allocator, "Please install the missing tools and try again."));
            log.info(try std.mem.concat(allocator, u8, &.{ try pc.blue(allocator, "You can also run: "), try pc.cyan(allocator, "psi tools"), try pc.blue(allocator, " to see installation instructions") }));
            exit(io, 1);
        }
        showInstructions = userChoice.value;
    }

    if (!showInstructions) {
        log.info("");
        log.info(try pc.blue(allocator, "Please install the missing tools and try again."));
        log.info(try std.mem.concat(allocator, u8, &.{ try pc.blue(allocator, "You can also run: "), try pc.cyan(allocator, "psi tools"), try pc.blue(allocator, " to see installation instructions") }));
        exit(io, 1);
    }

    try showInstallationInstructions(allocator, missingTools);

    exit(io, 1);
}
