const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const vault_zig = @import("vault-zig");
const api = @import("api-zig");
const lan_share = @import("lan-share-network-zig");
const pc = @import("../lib/picocolors.zig");
const prompts = @import("../lib/clack/prompts.zig");
const spinner_module = @import("../lib/spinner.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const commander = @import("../lib/commander.zig");
const jsonParse = @import("serialization-zig").json_parse.jsonParse;
const js_value = @import("bdb-zig").js_value;
const process_signals = @import("../lib/process-signals.zig");

//
// Names used from other files (the equivalent of the TypeScript imports).
//
const getVault = vault_zig.get_vault.getVault;
const getDefaultVaultType = vault_zig.get_vault.getDefaultVaultType;
const ISecret = vault_zig.vault.ISecret;
const log = &utils.log.log;
const confirm = prompts.confirm;
const intro = prompts.intro;
const outro = prompts.outro;
const text = prompts.text;
const password = prompts.password;
const select = prompts.select;
const isCancel = prompts.isCancel;
const note = prompts.note;
const multiline = prompts.multiline;
const spinner = spinner_module.spinner;
const exit = node_utils.termination.exit;
const pathExists = node_utils.fs.pathExists;
const LanShareSender = lan_share.lan_share_sender.LanShareSender;
const LanShareReceiver = lan_share.lan_share_receiver.LanShareReceiver;
const resolveSecretSharePayload = api.lan_share_resolve.resolveSecretSharePayload;
const importSecretPayload = api.lan_share_receive.importSecretPayload;
const ISecretSharePayload = api.lan_share.ISecretSharePayload;
const findSimilarSecretNames = init_cmd.findSimilarSecretNames;

//
// Secret types supported by the secrets CLI.
//
const SECRET_TYPES = [_][]const u8{ "api-key", "s3-credentials", "encryption-key", "plain" };

//
// `text.trim()`.
//
fn trim(value: []const u8) []const u8 {
    return utils.js_string.trim(value);
}

//
// Formats a message into the allocator (TypeScript: a template literal).
//
fn format(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(allocator, fmt, args);
}

//
// `text.padEnd(length)`: pads with spaces to a JavaScript (UTF-16) length.
//
fn padEnd(allocator: std.mem.Allocator, value: []const u8, length: usize) ![]const u8 {
    const current = commander.jsLength(value);
    if (current >= length) {
        return value;
    }
    const padding = try allocator.alloc(u8, length - current);
    @memset(padding, ' ');
    return std.mem.concat(allocator, u8, &.{ value, padding });
}

//
// True when the text is one of the supported secret types (`SECRET_TYPES.includes(type)`).
//
fn isSecretType(secretType: []const u8) bool {
    for (SECRET_TYPES) |supported| {
        if (std.mem.eql(u8, supported, secretType)) {
            return true;
        }
    }
    return false;
}

//
// Checks that the vault's required tools are present.
// Prints an actionable error and exits with code 1 if any prerequisite is missing.
//
fn checkVaultPrereqs(allocator: std.mem.Allocator, io: std.Io) !void {
    const vault = try getVault(getDefaultVaultType());
    const result = try vault.checkPrereqs(allocator, io);
    if (!result.ok) {
        log.@"error"(try pc.red(allocator, try format(allocator, "\u{2717} {s}", .{result.message orelse "undefined"})));
        exit(io, 1);
    }
}

//
// Options for the `secrets add` command.
//
pub const ISecretsAddOptions = struct {
    // Skip interactive prompts.
    yes: ?bool = null,

    // Secret name.
    name: ?[]const u8 = null,

    // Secret type.
    type: ?[]const u8 = null,

    // Secret value.
    value: ?[]const u8 = null,
};

//
// Options for the `secrets view` command.
//
pub const ISecretsViewOptions = struct {
    // Skip confirmation prompt.
    yes: ?bool = null,

    // Secret name to view.
    name: ?[]const u8 = null,

    // Print only the secret's raw value, with no name/type labels or colouring, so the output can be
    // captured and fed to another program. Requires --name and --yes.
    raw: ?bool = null,
};

//
// Options for the `secrets edit` command.
//
pub const ISecretsEditOptions = struct {
    // Skip interactive prompts.
    yes: ?bool = null,

    // Secret name to edit (identifier).
    name: ?[]const u8 = null,

    // New secret name (rename).
    newName: ?[]const u8 = null,

    // New secret value.
    value: ?[]const u8 = null,

    // Path to a file whose content is used as the new secret value (for multiline values such as PEM keys).
    valueFile: ?[]const u8 = null,
};

//
// Options for the `secrets remove` command.
//
pub const ISecretsRemoveOptions = struct {
    // Skip confirmation prompt.
    yes: ?bool = null,

    // Secret name to remove.
    name: ?[]const u8 = null,
};

//
// Options for the `secrets send` command.
//
pub const ISecretsSendOptions = struct {
    // Skip confirmation prompts.
    yes: ?bool = null,

    // Secret name to send.
    name: ?[]const u8 = null,

    // Pairing code to use instead of generating one.
    code: ?[]const u8 = null,

    // How long to wait for a receiver on the network, in milliseconds. The CLI never sets this, so a
    // real user always gets the 60 seconds the TypeScript waits. It is a field rather than a literal
    // in secretsSend so a test can drive the "no receiver" branch in milliseconds instead of waiting
    // out the minute: the branch is the same code either way, only how long it waits before giving up
    // differs. See ISecretsReceiveOptions.discoveryTimeoutMs, which is its twin.
    discoveryTimeoutMs: i64 = 60000,
};

//
// Options for the `secrets import` command.
//
pub const ISecretsImportOptions = struct {
    // Skip interactive prompts.
    yes: ?bool = null,

    // Path to the private key file.
    privateKey: ?[]const u8 = null,
};

//
// Options for the `secrets clear` command.
//
pub const ISecretsClearOptions = struct {
    // Skip confirmation prompt.
    yes: ?bool = null,
};

//
// Options for the `secrets receive` command (an inline type in TypeScript).
//
pub const ISecretsReceiveOptions = struct {
    // Skip confirmation prompts and field editing.
    yes: ?bool = null,

    // Pairing code shown on the sender (required with --yes).
    code: ?[]const u8 = null,

    // How long to wait for a sender on the network, in milliseconds. The CLI never sets this, so a
    // real user always gets the 60 seconds the TypeScript waits. It is a field rather than a literal
    // in secretsReceive so a test can drive the "no sender" branch in milliseconds instead of waiting
    // out the minute: the branch is the same code either way, only how long it waits before giving up
    // differs. See ISecretsSendOptions.discoveryTimeoutMs, which is its twin.
    discoveryTimeoutMs: i64 = 60000,
};

// Not ported: secretsCommand (the command group is registered in index.zig with the Zig commander, like every
// other command).

//
// Validates a name the user typed (`if (!value || value.trim().length === 0) return 'Name is required'`).
//
fn validateName(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    _ = context;
    if (value == null or trim(value.?).len == 0) {
        return "Name is required";
    }
    return null;
}

//
// Validates a value the user typed (`'Value is required'`).
//
fn validateValue(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    _ = context;
    if (value == null or trim(value.?).len == 0) {
        return "Value is required";
    }
    return null;
}

//
// Validates a multiline value the user typed (`'Value is required'`).
//
fn validateMultilineValue(context: ?*anyopaque, value: []const u8) ?[]const u8 {
    _ = context;
    if (trim(value).len == 0) {
        return "Value is required";
    }
    return null;
}

//
// Validates the private key path of `secrets import`: it is required and must exist. The context is the Io.
//
fn validatePrivateKeyPath(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    const io: *const std.Io = @ptrCast(@alignCast(context.?));
    if (value == null or trim(value.?).len == 0) {
        return "Path is required";
    }
    if (!pathExists(io.*, trim(value.?))) {
        return std.fmt.allocPrint(std.heap.smp_allocator, "File not found: {s}", .{trim(value.?)}) catch "File not found";
    }
    return null;
}

//
// Validates the pairing code the user typed (`/^\d{4}$/.test(val.trim())`).
//
fn validatePairingCode(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    _ = context;
    const trimmed = if (value) |typed| trim(typed) else "";
    if (value == null or trimmed.len != 4) {
        return "Please enter a 4-digit code";
    }
    for (trimmed) |character| {
        if (!std.ascii.isDigit(character)) {
            return "Please enter a 4-digit code";
        }
    }
    return null;
}

//
// Logs the "Did you mean" hint for a secret name that was not found, when there are similar names.
//
fn logSimilarSecretNames(allocator: std.mem.Allocator, io: std.Io, secretName: []const u8) !void {
    const similarSecretNames = try findSimilarSecretNames(allocator, io, secretName, null);
    if (similarSecretNames.len > 0) {
        var lines: std.ArrayList([]const u8) = .empty;
        for (similarSecretNames) |similarName| {
            try lines.append(allocator, try format(allocator, "  \u{2022} {s}", .{try pc.cyan(allocator, similarName)}));
        }
        log.info(try format(allocator, "Did you mean:\n{s}", .{try std.mem.join(allocator, "\n", lines.items)}));
    }
}

//
// Builds the select options for a list of secrets (`{ value: secret.name, label: `${secret.name} (${secret.type})` }`).
//
fn secretOptions(allocator: std.mem.Allocator, secrets: []const ISecret) ![]const prompts.Option {
    const options = try allocator.alloc(prompts.Option, secrets.len);
    for (secrets, 0..) |secret, index| {
        options[index] = .{
            .value = secret.name,
            .label = try format(allocator, "{s} ({s})", .{ secret.name, secret.type }),
        };
    }
    return options;
}

//
// psi secrets add: prompt for name, type, value, then store.
//
pub fn secretsAdd(allocator: std.mem.Allocator, io: std.Io, cmdOptions: *ISecretsAddOptions) !void {
    try checkVaultPrereqs(allocator, io);
    const vault = try getVault(getDefaultVaultType());

    if (cmdOptions.yes orelse false) {
        if (cmdOptions.name == null or cmdOptions.name.?.len == 0 or cmdOptions.type == null or cmdOptions.type.?.len == 0 or cmdOptions.value == null or cmdOptions.value.?.len == 0) {
            log.@"error"(try pc.red(allocator, "\u{2717} --name, --type, and --value are required with --yes"));
            exit(io, 1);
        }

        cmdOptions.name = trim(cmdOptions.name.?);

        if (!isSecretType(cmdOptions.type.?)) {
            log.@"error"(try pc.red(allocator, try format(allocator, "\u{2717} Invalid secret type \"{s}\". Must be one of: {s}", .{ cmdOptions.type.?, try std.mem.join(allocator, ", ", &SECRET_TYPES) })));
            exit(io, 1);
        }

        const existing = try vault.get(allocator, io, cmdOptions.name.?);
        if (existing != null) {
            log.@"error"(try pc.red(allocator, try format(allocator, "\u{2717} A secret named \"{s}\" already exists. Use \"secrets edit\" to update it.", .{cmdOptions.name.?})));
            exit(io, 1);
        }

        try vault.set(allocator, io, .{ .name = cmdOptions.name.?, .type = cmdOptions.type.?, .value = cmdOptions.value.? });
        log.info(try pc.green(allocator, try format(allocator, "\u{2713} Secret \"{s}\" added.", .{cmdOptions.name.?})));
        return;
    }

    try intro(io, try pc.cyan(allocator, "Add Secret"), .{});

    const name = try text(allocator, io, .{
        .message = "Secret name (e.g. cli:geocoding or db:abc123:s3):",
        .validate = .{ .context = null, .function = validateName },
    });

    if (isCancel(name)) {
        try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
        return;
    }

    const trimmedName = trim(name.value);
    const existing = try vault.get(allocator, io, trimmedName);
    if (existing != null) {
        try outro(io, try pc.red(allocator, try format(allocator, "\u{2717} A secret named \"{s}\" already exists. Use \"secrets edit\" to update it.", .{trimmedName})), .{});
        exit(io, 1);
    }

    var typeOptions: [SECRET_TYPES.len]prompts.Option = undefined;
    for (SECRET_TYPES, 0..) |secretType, index| {
        typeOptions[index] = .{ .value = secretType, .label = secretType };
    }
    const secretType = try select(allocator, io, .{
        .message = "Secret type:",
        .options = &typeOptions,
    });

    if (isCancel(secretType)) {
        try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
        return;
    }

    log.info(try pc.cyan(allocator, "Your secret will be stored securely in your OS keychain."));

    var value: []const u8 = undefined;

    if (std.mem.eql(u8, secretType.value, "encryption-key")) {
        const multilineResult = try multiline(allocator, io, .{
            .message = "Secret value (paste your key, then press Ctrl+D to submit):",
            .validate = .{ .context = null, .function = validateMultilineValue },
        });

        if (isCancel(multilineResult)) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return;
        }

        value = multilineResult.value;
    }
    else {
        const passwordResult = try password(allocator, io, .{
            .message = "Secret value:",
            .validate = .{ .context = null, .function = validateValue },
        });

        if (isCancel(passwordResult)) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return;
        }

        value = passwordResult.value orelse "";
    }

    try vault.set(allocator, io, .{ .name = trimmedName, .type = secretType.value, .value = value });

    try outro(io, try pc.green(allocator, try format(allocator, "\u{2713} Secret \"{s}\" added.", .{trimmedName})), .{});
}

//
// psi secrets list: print all secrets with masked values.
//
pub fn secretsList(allocator: std.mem.Allocator, io: std.Io) !void {
    try checkVaultPrereqs(allocator, io);
    const vault = try getVault(getDefaultVaultType());
    const secrets = try vault.list(allocator, io);

    if (secrets.len == 0) {
        log.info(try pc.yellow(allocator, "No secrets found."));
        return;
    }

    log.info(try pc.cyan(allocator, try format(allocator, "\n{s} {s} Value", .{ try padEnd(allocator, "Name", 40), try padEnd(allocator, "Type", 20) })));
    var rule: std.ArrayList(u8) = .empty;
    for (0..80) |_| {
        try rule.appendSlice(allocator, "\u{2500}");
    }
    log.info(rule.items);

    for (secrets) |secret| {
        const masked = "****";
        log.info(try format(allocator, "{s} {s} {s}", .{ try padEnd(allocator, secret.name, 40), try padEnd(allocator, secret.type, 20), masked }));
    }

    log.info("");
}

//
// Picks a secret from the vault with a select prompt (the shared body of view, edit and remove when no --name is
// given). Returns null when there are no secrets (after saying so) or when the prompt was cancelled.
//
fn selectSecret(allocator: std.mem.Allocator, io: std.Io, message: []const u8) !?[]const u8 {
    const vault = try getVault(getDefaultVaultType());
    const secrets = try vault.list(allocator, io);
    if (secrets.len == 0) {
        log.info(try pc.yellow(allocator, "No secrets found."));
        return null;
    }

    const selected = try select(allocator, io, .{
        .message = message,
        .options = try secretOptions(allocator, secrets),
    });

    if (isCancel(selected)) {
        try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
        return null;
    }

    return selected.value;
}

//
// Logs the entries of `Object.entries(string)`: each UTF-16 code unit under its index. A character outside the
// BMP is two code units, each a lone surrogate, which is written as U+FFFD.
//
fn logStringEntries(allocator: std.mem.Allocator, string: []const u8) !void {
    var byteIndex: usize = 0;
    var unitIndex: usize = 0;
    while (byteIndex < string.len) {
        const width = std.unicode.utf8ByteSequenceLength(string[byteIndex]) catch 1;
        const end = @min(byteIndex + width, string.len);
        if (width == 4) {
            log.info(try format(allocator, "  {d}: \u{FFFD}", .{unitIndex}));
            unitIndex += 1;
            log.info(try format(allocator, "  {d}: \u{FFFD}", .{unitIndex}));
        }
        else {
            log.info(try format(allocator, "  {d}: {s}", .{ unitIndex, string[byteIndex..end] }));
        }
        unitIndex += 1;
        byteIndex = end;
    }
}

//
// psi secrets view [name]: show the full value after confirmation.
//
pub fn secretsView(allocator: std.mem.Allocator, io: std.Io, cmdOptions: *ISecretsViewOptions) !void {
    try checkVaultPrereqs(allocator, io);
    const vault = try getVault(getDefaultVaultType());
    var secretName: ?[]const u8 = if (cmdOptions.name != null and cmdOptions.name.?.len > 0) cmdOptions.name else null;

    if (secretName == null) {
        if (cmdOptions.yes orelse false) {
            log.@"error"(try pc.red(allocator, "\u{2717} --name is required with --yes"));
            exit(io, 1);
        }

        secretName = try selectSecret(allocator, io, "Select a secret to view:") orelse {
            return;
        };
    }

    const secret = try vault.get(allocator, io, secretName.?) orelse {
        log.@"error"(try pc.red(allocator, try format(allocator, "\u{2717} No secret named \"{s}\" found.", .{secretName.?})));
        try logSimilarSecretNames(allocator, io, secretName.?);
        exit(io, 1);
    };

    if (!(cmdOptions.yes orelse false)) {
        const confirmed = try confirm(allocator, io, .{
            .message = try format(allocator, "Reveal the value of \"{s}\"? (This will display sensitive data.)", .{secretName.?}),
            .initialValue = false,
        });

        if (isCancel(confirmed) or !confirmed.value) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return;
        }
    }

    if (cmdOptions.raw orelse false) {
        // Bare value only, so a caller can capture it. Written straight to stdout rather than through
        // the logger so no labels, colour codes or trailing blank line contaminate the output.
        const stdout = prompts.common.resolveOutput(io, .{});
        try stdout.writeAll(secret.value);
        try stdout.flush();
        return;
    }

    log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "\nName: "), secret.name }));
    log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "Type: "), secret.type }));

    if (std.mem.eql(u8, secret.type, "s3-credentials")) {
        if (jsonParse(allocator, secret.value)) |parsed| {
            log.info(try pc.cyan(allocator, "Value:"));
            // Object.entries: the keys of an object, the indexes of an array, the UTF-16 code units of a string.
            switch (parsed) {
                .document => |document| {
                    for (document.fields.items) |field| {
                        log.info(try format(allocator, "  {s}: {s}", .{ field.key, try js_value.toString(allocator, field.value) }));
                    }
                },
                .array => |array| {
                    for (array, 0..) |item, index| {
                        log.info(try format(allocator, "  {d}: {s}", .{ index, try js_value.toString(allocator, item) }));
                    }
                },
                .string => |string| {
                    try logStringEntries(allocator, string);
                },
                // `Object.entries(null)` throws, and the catch logs the value.
                .null => {
                    log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "Value: "), secret.value }));
                },
                else => {},
            }
        }
        else |_| {
            log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "Value: "), secret.value }));
        }
    }
    else {
        log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "Value: "), secret.value }));
    }

    log.info("");
}

//
// psi secrets edit [name]: reload existing fields and re-prompt with current values pre-populated.
//
pub fn secretsEdit(allocator: std.mem.Allocator, io: std.Io, cmdOptions: *ISecretsEditOptions) !void {
    try checkVaultPrereqs(allocator, io);
    const vault = try getVault(getDefaultVaultType());
    var secretName: ?[]const u8 = if (cmdOptions.name != null and cmdOptions.name.?.len > 0) cmdOptions.name else null;

    if (secretName == null) {
        if (cmdOptions.yes orelse false) {
            log.@"error"(try pc.red(allocator, "\u{2717} --name is required with --yes"));
            exit(io, 1);
        }

        secretName = try selectSecret(allocator, io, "Select a secret to edit:") orelse {
            return;
        };
    }

    const secret = try vault.get(allocator, io, secretName.?) orelse {
        log.@"error"(try pc.red(allocator, try format(allocator, "\u{2717} No secret named \"{s}\" found.", .{secretName.?})));
        try logSimilarSecretNames(allocator, io, secretName.?);
        exit(io, 1);
    };

    if (cmdOptions.yes orelse false) {
        if (cmdOptions.newName) |newName| {
            if (newName.len > 0) {
                cmdOptions.newName = trim(newName);
            }
        }
        if (cmdOptions.valueFile) |valueFile| {
            if (valueFile.len > 0) {
                cmdOptions.valueFile = trim(valueFile);
            }
        }

        const hasNewName = cmdOptions.newName != null and cmdOptions.newName.?.len > 0;
        const hasValue = cmdOptions.value != null and cmdOptions.value.?.len > 0;
        const hasValueFile = cmdOptions.valueFile != null and cmdOptions.valueFile.?.len > 0;
        if (!hasNewName and !hasValue and !hasValueFile) {
            log.@"error"(try pc.red(allocator, "\u{2717} --new-name, --value, or --value-file is required with --yes"));
            exit(io, 1);
        }

        var updatedValue = secret.value;

        if (hasValueFile) {
            if (!pathExists(io, cmdOptions.valueFile.?)) {
                log.@"error"(try pc.red(allocator, try format(allocator, "\u{2717} File not found: {s}", .{cmdOptions.valueFile.?})));
                exit(io, 1);
            }

            updatedValue = try node_utils.node_fs.readFile(allocator, io, cmdOptions.valueFile.?);
        }
        else if (hasValue) {
            updatedValue = cmdOptions.value.?;
        }

        const updatedName = if (hasNewName) cmdOptions.newName.? else secret.name;

        if (!std.mem.eql(u8, updatedName, secret.name)) {
            try vault.delete(allocator, io, secret.name);
        }

        try vault.set(allocator, io, .{ .name = updatedName, .type = secret.type, .value = updatedValue });
        log.info(try pc.green(allocator, try format(allocator, "\u{2713} Secret \"{s}\" updated.", .{updatedName})));
        return;
    }

    try intro(io, try pc.cyan(allocator, try format(allocator, "Edit Secret: {s}", .{secretName.?})), .{});

    const newName = try text(allocator, io, .{
        .message = "Secret name:",
        .initialValue = secret.name,
        .validate = .{ .context = null, .function = validateName },
    });

    if (isCancel(newName)) {
        try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
        return;
    }

    log.info(try pc.cyan(allocator, "Your secret will be stored securely in your OS keychain."));

    var newValue: ?[]const u8 = null;

    if (std.mem.eql(u8, secret.type, "encryption-key")) {
        const multilineResult = try multiline(allocator, io, .{
            .message = "New value (paste your key, then press Ctrl+D to submit; leave empty and Ctrl+D to keep current):",
        });
        if (isCancel(multilineResult)) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return;
        }
        newValue = multilineResult.value;
    }
    else {
        const passwordResult = try password(allocator, io, .{
            .message = "New value (leave blank to keep current):",
        });
        if (isCancel(passwordResult)) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return;
        }
        newValue = passwordResult.value;
    }

    const updatedName = trim(newName.value);
    const updatedValue = if (newValue != null and newValue.?.len > 0) trim(newValue.?) else secret.value;

    if (std.mem.eql(u8, updatedName, secret.name) and std.mem.eql(u8, updatedValue, secret.value)) {
        try outro(io, try pc.yellow(allocator, "No changes made."), .{});
        return;
    }

    if (!std.mem.eql(u8, updatedName, secret.name)) {
        try vault.delete(allocator, io, secret.name);
    }

    try vault.set(allocator, io, .{ .name = updatedName, .type = secret.type, .value = updatedValue });
    try outro(io, try pc.green(allocator, try format(allocator, "\u{2713} Secret \"{s}\" updated.", .{updatedName})), .{});
}

//
// psi secrets remove [name]: remove a secret after confirmation.
//
pub fn secretsRemove(allocator: std.mem.Allocator, io: std.Io, cmdOptions: *ISecretsRemoveOptions) !void {
    try checkVaultPrereqs(allocator, io);
    const vault = try getVault(getDefaultVaultType());
    var secretName: ?[]const u8 = if (cmdOptions.name != null and cmdOptions.name.?.len > 0) cmdOptions.name else null;

    if (secretName == null) {
        if (cmdOptions.yes orelse false) {
            log.@"error"(try pc.red(allocator, "\u{2717} --name is required with --yes"));
            exit(io, 1);
        }

        secretName = try selectSecret(allocator, io, "Select a secret to delete:") orelse {
            return;
        };
    }

    const secret = try vault.get(allocator, io, secretName.?);

    if (secret == null) {
        log.@"error"(try pc.red(allocator, try format(allocator, "\u{2717} No secret named \"{s}\" found.", .{secretName.?})));
        try logSimilarSecretNames(allocator, io, secretName.?);
        exit(io, 1);
    }

    if (!(cmdOptions.yes orelse false)) {
        const confirmed = try confirm(allocator, io, .{
            .message = try format(allocator, "Delete secret \"{s}\"? This cannot be undone.", .{secretName.?}),
            .initialValue = false,
        });

        if (isCancel(confirmed) or !confirmed.value) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return;
        }
    }

    try vault.delete(allocator, io, secretName.?);
    try outro(io, try pc.green(allocator, try format(allocator, "\u{2713} Secret \"{s}\" deleted.", .{secretName.?})), .{});
}

//
// psi secrets clear: remove all secrets after confirmation.
//
pub fn secretsClear(allocator: std.mem.Allocator, io: std.Io, cmdOptions: *ISecretsClearOptions) !void {
    try checkVaultPrereqs(allocator, io);
    const vault = try getVault(getDefaultVaultType());
    const secrets = try vault.list(allocator, io);

    if (secrets.len == 0) {
        log.info(try pc.yellow(allocator, "No secrets found."));
        return;
    }

    if (!(cmdOptions.yes orelse false)) {
        log.info(try pc.cyan(allocator, "\nSecrets to be deleted:"));
        for (secrets) |secret| {
            log.info(try format(allocator, "  {s} ({s})", .{ secret.name, secret.type }));
        }
        log.info("");

        const firstConfirm = try confirm(allocator, io, .{
            .message = try format(allocator, "Delete all {d} secret(s)? This cannot be undone.", .{secrets.len}),
            .initialValue = false,
        });

        if (isCancel(firstConfirm) or !firstConfirm.value) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return;
        }

        const secondConfirm = try confirm(allocator, io, .{
            .message = "Are you sure? All secrets will be permanently deleted.",
            .initialValue = false,
        });

        if (isCancel(secondConfirm) or !secondConfirm.value) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return;
        }
    }

    for (secrets) |secret| {
        try vault.delete(allocator, io, secret.name);
    }

    try outro(io, try pc.green(allocator, try format(allocator, "\u{2713} Deleted {d} secret(s).", .{secrets.len})), .{});
}

//
// The name a key file is imported as: its last `/`-separated part without the `.key` extension
// (`privatePath.split('/').pop()?.replace(/\.key$/, '')`).
//
fn keyNameFromPath(privatePath: []const u8) []const u8 {
    const fileName = if (std.mem.lastIndexOfScalar(u8, privatePath, '/')) |index| privatePath[index + 1 ..] else privatePath;
    if (std.mem.endsWith(u8, fileName, ".key")) {
        return fileName[0 .. fileName.len - ".key".len];
    }
    return fileName;
}

//
// psi secrets import: import a .key / .key.pub PEM file pair into the secrets store.
//
pub fn secretsImport(allocator: std.mem.Allocator, io: std.Io, cmdOptions: *ISecretsImportOptions) !void {
    try checkVaultPrereqs(allocator, io);
    if (cmdOptions.yes orelse false) {
        if (cmdOptions.privateKey == null or cmdOptions.privateKey.?.len == 0) {
            log.@"error"(try pc.red(allocator, "\u{2717} --private-key is required with --yes"));
            exit(io, 1);
        }

        const privatePath = trim(cmdOptions.privateKey.?);
        if (!pathExists(io, privatePath)) {
            log.@"error"(try pc.red(allocator, try format(allocator, "\u{2717} File not found: {s}", .{privatePath})));
            exit(io, 1);
        }

        const importedName = keyNameFromPath(privatePath);
        const keyName = if (importedName.len > 0) importedName else "imported-key";
        const privateKeyPem = try node_utils.node_fs.readFile(allocator, io, privatePath);
        const vault = try getVault(getDefaultVaultType());
        try vault.set(allocator, io, .{ .name = keyName, .type = "encryption-key", .value = privateKeyPem });
        log.info(try pc.green(allocator, try format(allocator, "\u{2713} Key imported as \"{s}\".", .{keyName})));
        return;
    }

    try intro(io, try pc.cyan(allocator, "Import Encryption Key"), .{});

    const privateKeyPath = try text(allocator, io, .{
        .message = "Path to the private key file (.key):",
        .validate = .{ .context = @constCast(@ptrCast(&io)), .function = validatePrivateKeyPath },
    });

    if (isCancel(privateKeyPath)) {
        try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
        return;
    }

    const privatePath = trim(privateKeyPath.value);
    const keyName = keyNameFromPath(privatePath);
    const privateKeyPem = try node_utils.node_fs.readFile(allocator, io, privatePath);
    const vault = try getVault(getDefaultVaultType());
    try vault.set(allocator, io, .{ .name = keyName, .type = "encryption-key", .value = privateKeyPem });
    try outro(io, try pc.green(allocator, try format(allocator, "\u{2713} Key imported as \"{s}\".", .{keyName})), .{});
}

//
// Converts a secret share payload to the JSON object the sender sends (the object literal of
// resolveSecretSharePayload, keys in its order).
//
fn payloadToJson(allocator: std.mem.Allocator, payload: ISecretSharePayload) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "type", .{ .string = payload.type });
    try object.put(allocator, "name", .{ .string = payload.name });
    try object.put(allocator, "secretType", .{ .string = payload.secretType });
    try object.put(allocator, "value", .{ .string = payload.value });
    return .{ .object = object };
}

//
// The SIGINT listener of `secrets send` (`() => { sender.cancel(); }`).
//
fn cancelSender(context: *anyopaque) void {
    const sender: *LanShareSender = @ptrCast(@alignCast(context));
    sender.cancel();
}

//
// The SIGINT listener of `secrets receive` (`() => { receiver.cancel(); }`).
//
fn cancelReceiver(context: *anyopaque) void {
    const receiver: *LanShareReceiver = @ptrCast(@alignCast(context));
    receiver.cancel();
}

//
// Writes the note that both devices must be on the same local network.
//
fn networkRequirementNote(allocator: std.mem.Allocator, io: std.Io) !void {
    try note(
        allocator,
        io,
        "Both devices must be on the same local network (wired or Wi-Fi).\nThis does not work over the internet.",
        try pc.cyan(allocator, "\u{2139} Network Requirement"),
        .{},
    );
}

//
// psi secrets send [name]: share a secret with another device over the LAN.
//
pub fn secretsSend(allocator: std.mem.Allocator, io: std.Io, cmdOptions: *ISecretsSendOptions) !void {
    try checkVaultPrereqs(allocator, io);
    try intro(io, try pc.cyan(allocator, "Send Secret"), .{});

    const vault = try getVault(getDefaultVaultType());
    var secretName: []const u8 = undefined;

    try networkRequirementNote(allocator, io);

    if (cmdOptions.name != null and cmdOptions.name.?.len > 0) {
        const secret = try vault.get(allocator, io, cmdOptions.name.?);
        if (secret == null) {
            log.@"error"(try pc.red(allocator, try format(allocator, "\u{2717} No secret named \"{s}\" found.", .{cmdOptions.name.?})));
            try logSimilarSecretNames(allocator, io, cmdOptions.name.?);
            exit(io, 1);
        }
        secretName = cmdOptions.name.?;
    }
    else {
        // Pick from all vault secrets
        const secrets = try vault.list(allocator, io);
        if (secrets.len == 0) {
            log.info(try pc.yellow(allocator, "No secrets found."));
            log.info(try pc.dim(allocator, "Use \"psi secrets add\" to add a secret first."));
            return;
        }

        const selected = try select(allocator, io, .{
            .message = "Select a secret to send:",
            .options = try secretOptions(allocator, secrets),
        });

        if (isCancel(selected)) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return;
        }

        secretName = selected.value;
    }

    log.info(try pc.dim(allocator, "Hint: Run `psi secrets receive` on another device to receive this secret."));

    // Build the payload
    const payload = try resolveSecretSharePayload(allocator, io, secretName);

    log.info(try pc.cyan(allocator, "\nSecret to send:"));
    log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "  Name: "), secretName }));
    log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "  Type: "), payload.secretType }));
    log.info("");

    // Create sender (generates or uses supplied pairing code)
    var sender = try LanShareSender.init(allocator, io, try payloadToJson(allocator, payload), cmdOptions.code);

    // Display the pairing code: the user must enter this on the receiver device
    log.info(try pc.cyan(allocator, try format(allocator, "  Pairing code: {s}", .{try pc.bold(allocator, sender.pairingCode)})));
    log.info(try pc.dim(allocator, "  Enter this code on the receiver device, then wait."));
    log.info("");

    const spin = try spinner(allocator, io, !(cmdOptions.yes orelse false));
    try spin.start("Waiting for receiver on the local network... (Ctrl+C to cancel)");

    // TODO: this mirrors a bug in the TypeScript (secrets.ts secretsSend) until both are fixed: the share-cancel hang
    // explained at the TODO in dbs.zig dbsSend. Ctrl+C is taken over only after the pairing code is shown, so a
    // SIGINT between the two is lost when SIGINT was inherited as ignored and the sender waits out 60 seconds.
    const sigintHandler: process_signals.ISignalListener = .{ .context = &sender, .function = cancelSender };
    try process_signals.on(.SIGINT, sigintHandler);

    const endpoint = try sender.waitForReceiver(io, cmdOptions.discoveryTimeoutMs);
    try process_signals.removeListener(.SIGINT, sigintHandler);

    if (endpoint == null) {
        // Discovery now ignores receivers whose pairing code does not match, which stops two shares
        // hijacking each other but also means a mistyped code ends as a plain timeout. This tells
        // the two apart.
        //
        // A receiver that announced a different pairing code is a mistyped code, not an absent
        // device, and saying so saves the user hunting the wrong problem.
        if (sender.sawMismatchedReceiver) {
            try spin.stop(try pc.yellow(allocator, "Pairing code rejected: a device was found but it is using a different code."));
        }
        else {
            try spin.stop(try pc.yellow(allocator, "No receiver found within 60 seconds."));
        }
        return;
    }

    try spin.stop(try pc.green(allocator, "Receiver found!"));

    const success = try sender.send(endpoint.?);

    if (success) {
        try outro(io, try pc.green(allocator, "\u{2713} Secret sent successfully!"), .{});
    }
    else {
        log.@"error"(try pc.red(allocator, "\u{2717} Pairing code rejected by receiver."));
        exit(io, 1);
    }
}

//
// Reads a string field of a received payload.
//
fn payloadString(payload: std.json.Value, field: []const u8) ![]const u8 {
    if (payload == .object) {
        if (payload.object.get(field)) |value| {
            if (value == .string) {
                return value.string;
            }
        }
    }
    return utils.errors.throwError("The received secret has no \"{s}\" text field.", .{field});
}

//
// psi secrets receive: receive a secret from another device over the LAN.
//
pub fn secretsReceive(allocator: std.mem.Allocator, io: std.Io, cmdOptions: *ISecretsReceiveOptions) !void {
    try checkVaultPrereqs(allocator, io);
    try intro(io, try pc.cyan(allocator, "Receive Secret"), .{});

    const skipPrompts = cmdOptions.yes orelse false;

    try networkRequirementNote(allocator, io);

    log.info(try pc.dim(allocator, "Hint: Run `psi secrets send` on another device to send a secret."));

    var code: []const u8 = undefined;

    if (skipPrompts) {
        if (cmdOptions.code == null or cmdOptions.code.?.len == 0) {
            log.@"error"(try pc.red(allocator, "\u{2717} --code is required with --yes"));
            exit(io, 1);
        }
        code = cmdOptions.code.?;
    }
    else {
        const codeInput = try text(allocator, io, .{
            .message = "Enter the 4-digit pairing code shown on the sender:",
            .validate = .{ .context = null, .function = validatePairingCode },
        });

        if (isCancel(codeInput)) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return;
        }

        code = trim(codeInput.value);
    }

    var receiver = LanShareReceiver.init(io, cmdOptions.discoveryTimeoutMs);
    defer receiver.deinit();
    try receiver.start(code);

    const spin = try spinner(allocator, io, !skipPrompts);
    try spin.start("Waiting for sender on the local network... (Ctrl+C to cancel)");

    // TODO: this mirrors the TypeScript (secrets.ts secretsReceive) until both are fixed: the share-cancel hang
    // explained at the TODO in dbs.zig dbsSend. Ctrl+C is taken over only after the waiting message is shown,
    // as the TypeScript does, so a SIGINT between the two is lost when SIGINT was inherited as ignored.
    const sigintHandler: process_signals.ISignalListener = .{ .context = &receiver, .function = cancelReceiver };
    try process_signals.on(.SIGINT, sigintHandler);

    const rawPayload = try receiver.receive();
    try process_signals.removeListener(.SIGINT, sigintHandler);

    if (rawPayload == null) {
        try spin.stop(try pc.yellow(allocator, "No sender connected within 60 seconds."));
        return;
    }

    try spin.stop(try pc.green(allocator, "Payload received!"));

    const payload: ISecretSharePayload = .{
        .type = try payloadString(rawPayload.?, "type"),
        .name = try payloadString(rawPayload.?, "name"),
        .secretType = try payloadString(rawPayload.?, "secretType"),
        .value = try payloadString(rawPayload.?, "value"),
    };

    log.info(try pc.cyan(allocator, "\nReceived secret:"));
    log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "  Type: "), payload.secretType }));
    log.info("");

    var saveName: []const u8 = undefined;

    if (skipPrompts) {
        saveName = payload.name;
    }
    else {
        // Ask what name to save it as, pre-populated with the sender's name.
        const nameInput = try text(allocator, io, .{
            .message = "Save secret as (name):",
            .initialValue = payload.name,
            .validate = .{ .context = null, .function = validateName },
        });

        if (isCancel(nameInput)) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return;
        }

        saveName = trim(nameInput.value);
    }

    try importSecretPayload(allocator, io, payload, saveName);

    try outro(io, try pc.green(allocator, try format(allocator, "\u{2713} Secret \"{s}\" imported successfully!", .{saveName})), .{});
}
