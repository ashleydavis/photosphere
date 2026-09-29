const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const vault_zig = @import("vault-zig");
const encryption = @import("encryption-zig");
const api = @import("api-zig");
const lan_share = @import("lan-share-network-zig");
const pc = @import("../lib/picocolors.zig");
const prompts = @import("../lib/clack/prompts.zig");
const spinner_module = @import("../lib/spinner.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const commander = @import("../lib/commander.zig");
const process_signals = @import("../lib/process-signals.zig");

//
// Names used from other files (the equivalent of the TypeScript imports).
//
const getVault = vault_zig.get_vault.getVault;
const getDefaultVaultType = vault_zig.get_vault.getDefaultVaultType;
const IVault = vault_zig.vault.IVault;
const log = &utils.log.log;
const getDatabases = node_api.databases_config.getDatabases;
const addDatabaseEntry = node_api.databases_config.addDatabaseEntry;
const updateDatabaseEntry = node_api.databases_config.updateDatabaseEntry;
const removeDatabaseEntry = node_api.databases_config.removeDatabaseEntry;
const findDatabase = node_api.databases_config.findDatabase;
const IDatabaseEntry = node_api.databases_config.IDatabaseEntry;
const confirm = prompts.confirm;
const intro = prompts.intro;
const outro = prompts.outro;
const text = prompts.text;
const select = prompts.select;
const isCancel = prompts.isCancel;
const note = prompts.note;
const spinner = spinner_module.spinner;
const exit = node_utils.termination.exit;
const generateKeyPair = encryption.key_utils.generateKeyPair;
const exportPrivateKey = encryption.node_crypto.exportPrivateKey;
const LanShareSender = lan_share.lan_share_sender.LanShareSender;
const LanShareReceiver = lan_share.lan_share_receiver.LanShareReceiver;
const resolveDatabaseSharePayload = api.lan_share_resolve.resolveDatabaseSharePayload;
const importDatabasePayload = api.lan_share_receive.importDatabasePayload;
const IDatabaseSharePayload = api.lan_share.IDatabaseSharePayload;
const ConflictResolver = api.lan_share.ConflictResolver;
const IConflictResolution = api.lan_share.IConflictResolution;
const findSimilarDatabaseNames = init_cmd.findSimilarDatabaseNames;
const findSimilarKeyNames = init_cmd.findSimilarKeyNames;
const findSimilarSecretNames = init_cmd.findSimilarSecretNames;

//
// Options for the `dbs add` command.
//
pub const IDbsAddOptions = struct {
    // Skip interactive prompts.
    yes: ?bool = null,

    // Database name.
    name: ?[]const u8 = null,

    // Database description.
    description: ?[]const u8 = null,

    // Database path.
    path: ?[]const u8 = null,

    // S3 credential secret name.
    s3Cred: ?[]const u8 = null,

    // Encryption key secret name.
    encryptionKey: ?[]const u8 = null,

    // Geocoding API key secret name.
    geocodingKey: ?[]const u8 = null,
};

//
// Options for the `dbs view` command.
//
pub const IDbsViewOptions = struct {
    // Skip interactive selection (requires --name or --path).
    yes: ?bool = null,

    // Database name to look up.
    name: ?[]const u8 = null,

    // Database path to look up.
    path: ?[]const u8 = null,
};

//
// Options for the `dbs edit` command.
//
pub const IDbsEditOptions = struct {
    // Skip interactive prompts.
    yes: ?bool = null,

    // Database name to edit (identifier).
    name: ?[]const u8 = null,

    // New database name (rename).
    newName: ?[]const u8 = null,

    // New description.
    description: ?[]const u8 = null,

    // New database path.
    path: ?[]const u8 = null,

    // S3 credential secret name.
    s3Cred: ?[]const u8 = null,

    // Encryption key secret name.
    encryptionKey: ?[]const u8 = null,

    // Geocoding API key secret name.
    geocodingKey: ?[]const u8 = null,
};

//
// Options for the `dbs remove` command.
//
pub const IDbsRemoveOptions = struct {
    // Skip confirmation prompt.
    yes: ?bool = null,

    // Database name to look up.
    name: ?[]const u8 = null,

    // Database path to look up.
    path: ?[]const u8 = null,
};

//
// Options for the `dbs send` command.
//
pub const IDbsSendOptions = struct {
    // Skip confirmation prompts.
    yes: ?bool = null,

    // Database name to look up.
    name: ?[]const u8 = null,

    // Database path to look up.
    path: ?[]const u8 = null,

    // Pairing code to use instead of generating one.
    code: ?[]const u8 = null,
};

//
// Options for the `dbs clear` command.
//
pub const IDbsClearOptions = struct {
    // Skip confirmation prompt.
    yes: ?bool = null,
};

//
// Options for the `dbs receive` command (an inline type in TypeScript).
//
pub const IDbsReceiveOptions = struct {
    // Skip confirmation prompts and field editing.
    yes: ?bool = null,

    // Pairing code shown on the other device (required with --yes).
    code: ?[]const u8 = null,
};

//
// `text.trim()`: removes the ASCII characters JavaScript's String.prototype.trim removes.
//
fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\n\r\x0b\x0c");
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
// `'─'.repeat(count)`: a rule of box-drawing characters.
//
fn rule(allocator: std.mem.Allocator, count: usize) ![]const u8 {
    var line: std.ArrayList(u8) = .empty;
    for (0..count) |_| {
        try line.appendSlice(allocator, "\u{2500}");
    }
    return line.items;
}

//
// True when an option holds a non-empty string (the truthiness test `if (cmdOptions.name)`).
//
fn isGiven(value: ?[]const u8) bool {
    return value != null and value.?.len > 0;
}

//
// Trims an option when it is given (`if (option) { option = option.trim(); }`).
//
fn trimGiven(value: ?[]const u8) ?[]const u8 {
    if (isGiven(value)) {
        return trim(value.?);
    }
    return value;
}

//
// Returns true if the path refers to a local filesystem location rather than
// a network-accessible storage like S3. Local paths won't be valid on other devices.
//
fn isLocalPath(dbPath: []const u8) bool {
    return !std.mem.startsWith(u8, dbPath, "s3:");
}

//
// Finds a database entry by its exact path.
//
fn findDatabaseByPath(allocator: std.mem.Allocator, io: std.Io, dbPath: []const u8) !?IDatabaseEntry {
    const databases = try getDatabases(allocator, io);
    for (databases) |dbEntry| {
        if (std.mem.eql(u8, dbEntry.path, dbPath)) {
            return dbEntry;
        }
    }
    return null;
}

//
// Finds a database entry by name or path. Name takes precedence if both are provided.
//
fn findDatabaseByIdentifier(allocator: std.mem.Allocator, io: std.Io, name: ?[]const u8, dbPath: ?[]const u8) !?IDatabaseEntry {
    if (isGiven(name)) {
        return findDatabase(allocator, io, name.?);
    }
    if (isGiven(dbPath)) {
        return findDatabaseByPath(allocator, io, dbPath.?);
    }
    return null;
}

//
// Logs the "Did you mean" hint listing similar names, when there are any.
//
fn logDidYouMean(allocator: std.mem.Allocator, similarNames: []const []const u8) !void {
    if (similarNames.len > 0) {
        var lines: std.ArrayList([]const u8) = .empty;
        for (similarNames) |similarName| {
            try lines.append(allocator, try format(allocator, "  \u{2022} {s}", .{try pc.cyan(allocator, similarName)}));
        }
        log.info(try format(allocator, "Did you mean:\n{s}", .{try std.mem.join(allocator, "\n", lines.items)}));
    }
}

//
// Logs the error for a name or path that matched no database, with the "Did you mean" hint when a name was given,
// and exits with code 1 (the shared not-found branch of view, remove and send).
//
fn exitNoMatchingDatabase(allocator: std.mem.Allocator, io: std.Io, name: ?[]const u8) !noreturn {
    log.@"error"(try pc.red(allocator, "\u{2717} No database matching the given name or path was found."));
    if (isGiven(name)) {
        try logDidYouMean(allocator, try findSimilarDatabaseNames(allocator, io, name.?));
    }
    exit(io, 1);
}

//
// Checks that the secrets named by --encryption-key, --s3-cred and --geocoding-key are in the vault (the shared
// checks of `dbs add --yes` and `dbs edit --yes`). Logs the error with the "Did you mean" hint and exits with code 1
// for the first one that is missing.
//
fn checkSecretsExist(allocator: std.mem.Allocator, io: std.Io, encryptionKey: ?[]const u8, s3Cred: ?[]const u8, geocodingKey: ?[]const u8) !void {
    if (isGiven(encryptionKey)) {
        const vault = try getVault(getDefaultVaultType());
        const encryptionKeySecret = try vault.get(allocator, io, encryptionKey.?);
        if (encryptionKeySecret == null) {
            log.@"error"(try pc.red(allocator, try format(allocator, "\u{2717} Encryption key \"{s}\" not found in vault.", .{encryptionKey.?})));
            try logDidYouMean(allocator, try findSimilarKeyNames(allocator, io, encryptionKey.?));
            exit(io, 1);
        }
    }

    if (isGiven(s3Cred)) {
        const vault = try getVault(getDefaultVaultType());
        const s3CredSecret = try vault.get(allocator, io, s3Cred.?);
        if (s3CredSecret == null) {
            log.@"error"(try pc.red(allocator, try format(allocator, "\u{2717} S3 credential \"{s}\" not found in vault.", .{s3Cred.?})));
            try logDidYouMean(allocator, try findSimilarSecretNames(allocator, io, s3Cred.?, "s3-credentials"));
            exit(io, 1);
        }
    }

    if (isGiven(geocodingKey)) {
        const vault = try getVault(getDefaultVaultType());
        const geocodingKeySecret = try vault.get(allocator, io, geocodingKey.?);
        if (geocodingKeySecret == null) {
            log.@"error"(try pc.red(allocator, try format(allocator, "\u{2717} Geocoding API key \"{s}\" not found in vault.", .{geocodingKey.?})));
            try logDidYouMean(allocator, try findSimilarSecretNames(allocator, io, geocodingKey.?, "api-key"));
            exit(io, 1);
        }
    }
}

//
// Returns the prompt shown when picking a secret of the given type.
//
fn promptForSecretType(allocator: std.mem.Allocator, secretType: []const u8) ![]const u8 {
    if (std.mem.eql(u8, secretType, "s3-credentials")) {
        return "S3 credentials:";
    }
    if (std.mem.eql(u8, secretType, "encryption-key")) {
        return "Encryption key:";
    }
    if (std.mem.eql(u8, secretType, "api-key")) {
        return "Geocoding API key:";
    }
    return format(allocator, "{s}:", .{secretType});
}

//
// Presents a select prompt to pick or create a shared secret of the given type.
// Returns the secret name to store on the database entry, or undefined for "None".
//
fn pickOrCreateSecret(allocator: std.mem.Allocator, io: std.Io, secretType: []const u8, dbName: []const u8, currentName: ?[]const u8) !?[]const u8 {
    const vault = try getVault(getDefaultVaultType());
    const secrets = try vault.list(allocator, io);

    // Build the select options: None, every existing secret of the matching type, then "Create new".
    var options: std.ArrayList(prompts.Option) = .empty;
    try options.append(allocator, .{
        .value = "__none__",
        .label = "None",
    });

    for (secrets) |secret| {
        if (std.mem.eql(u8, secret.type, secretType)) {
            try options.append(allocator, .{
                .value = secret.name,
                .label = secret.name,
            });
        }
    }

    try options.append(allocator, .{
        .value = "__create__",
        .label = "+ Create new",
    });

    // Determine the initial value (highlight current selection when editing).
    const initialValue = if (isGiven(currentName)) currentName.? else "__none__";

    const selected = try select(allocator, io, .{
        .message = try promptForSecretType(allocator, secretType),
        .options = options.items,
        .initialValue = initialValue,
    });

    if (isCancel(selected)) {
        try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
        exit(io, 0);
    }

    const selectedValue = selected.value;

    if (std.mem.eql(u8, selectedValue, "__none__")) {
        return null;
    }

    if (std.mem.eql(u8, selectedValue, "__create__")) {
        return try createSharedSecret(allocator, io, secretType, dbName);
    }

    return selectedValue;
}

//
// The value S3 credentials are stored with (the object literal createSharedSecret stringifies, keys in its order;
// the endpoint is only added when one was given).
//
const IS3CredentialsValue = struct {
    // AWS region.
    region: []const u8,

    // Access key ID.
    accessKeyId: []const u8,

    // Secret access key.
    secretAccessKey: []const u8,

    // Optional custom endpoint URL.
    endpoint: ?[]const u8,
};

//
// Inline creation flow for a new shared secret of the given type.
// Returns the secret name (which is also the vault key).
//
// The name is inferred from the database name and secret type
// (e.g. "mydb:s3" for s3-credentials on database "mydb"). If that
// inferred name is already taken in the vault, the user is prompted
// for a different one.
//
fn createSharedSecret(allocator: std.mem.Allocator, io: std.Io, secretType: []const u8, dbName: []const u8) ![]const u8 {
    const vault = try getVault(getDefaultVaultType());

    const inferredName = try inferSecretName(allocator, dbName, secretType);
    const secretName = try resolveUniqueSecretName(allocator, io, vault, inferredName, secretType);

    if (std.mem.eql(u8, secretType, "s3-credentials")) {
        const endpoint = try promptOptional(allocator, io, "Endpoint URL (leave blank for AWS):");
        const region = try promptRequired(allocator, io, "Region (e.g. us-east-1):");
        const accessKeyId = try promptRequired(allocator, io, "Access Key ID:");
        const secretAccessKey = try promptRequired(allocator, io, "Secret Access Key:");

        const value: IS3CredentialsValue = .{
            .region = region,
            .accessKeyId = accessKeyId,
            .secretAccessKey = secretAccessKey,
            .endpoint = endpoint,
        };

        try vault.set(allocator, io, .{
            .name = secretName,
            .type = "s3-credentials",
            .value = try std.json.Stringify.valueAlloc(allocator, value, .{
                .emit_null_optional_fields = false,
            }),
        });

        log.info(try pc.green(allocator, try format(allocator, "  \u{2713} S3 credential \"{s}\" created", .{secretName})));
    }
    else if (std.mem.eql(u8, secretType, "encryption-key")) {
        const keyChoice = try select(allocator, io, .{
            .message = "How would you like to provide the key?",
            .options = &.{
                .{
                    .value = "generate",
                    .label = "Generate a new RSA-4096 key pair",
                },
                .{
                    .value = "import",
                    .label = "Import existing PEM files",
                },
            },
        });

        if (isCancel(keyChoice)) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            exit(io, 0);
        }

        var privateKeyPem: []const u8 = undefined;

        if (std.mem.eql(u8, keyChoice.value, "generate")) {
            const keyPair = try generateKeyPair(allocator, io);
            privateKeyPem = try exportPrivateKey(allocator, keyPair.privateKey, .pem);
        }
        else {
            const privatePath = try promptRequired(allocator, io, "Path to private key (.key):");
            privateKeyPem = try std.Io.Dir.cwd().readFileAlloc(io, privatePath, allocator, .unlimited);
        }

        try vault.set(allocator, io, .{
            .name = secretName,
            .type = "encryption-key",
            .value = privateKeyPem,
        });

        log.info(try pc.green(allocator, try format(allocator, "  \u{2713} Encryption key \"{s}\" created", .{secretName})));
    }
    else if (std.mem.eql(u8, secretType, "api-key")) {
        const apiKey = try promptRequired(allocator, io, "API key value:");

        try vault.set(allocator, io, .{
            .name = secretName,
            .type = "api-key",
            .value = apiKey,
        });

        log.info(try pc.green(allocator, try format(allocator, "  \u{2713} API key \"{s}\" created", .{secretName})));
    }

    return secretName;
}

//
// Maps a secret type to a short suffix used in inferred vault key names.
//
fn suffixForSecretType(secretType: []const u8) []const u8 {
    if (std.mem.eql(u8, secretType, "s3-credentials")) {
        return "s3";
    }
    if (std.mem.eql(u8, secretType, "encryption-key")) {
        return "encryption";
    }
    if (std.mem.eql(u8, secretType, "api-key")) {
        return "geocoding";
    }
    return secretType;
}

//
// Builds the default vault key name for a secret of the given type linked to the given database.
//
fn inferSecretName(allocator: std.mem.Allocator, dbName: []const u8, secretType: []const u8) ![]const u8 {
    return format(allocator, "{s}:{s}", .{ dbName, suffixForSecretType(secretType) });
}

//
// Returns the inferred name when it is free in the vault, otherwise prompts the user
// for a different name and rejects any that are already taken.
//
fn resolveUniqueSecretName(allocator: std.mem.Allocator, io: std.Io, vault: IVault, inferredName: []const u8, secretType: []const u8) ![]const u8 {
    const existing = try vault.get(allocator, io, inferredName);
    if (existing == null) {
        return inferredName;
    }
    log.info(try pc.yellow(allocator, try format(allocator, "  \u{26a0} A secret named \"{s}\" already exists. Choose a different name.", .{inferredName})));
    while (true) {
        const candidate = try promptRequired(allocator, io, try format(allocator, "Name for this {s}:", .{secretType}));
        const conflict = try vault.get(allocator, io, candidate);
        if (conflict == null) {
            return candidate;
        }
        log.@"error"(try pc.red(allocator, try format(allocator, "\u{2717} A secret named \"{s}\" already exists in the vault. Choose a different name.", .{candidate})));
    }
}

//
// Validates a required value the user typed (`'This field is required'`).
//
fn validateRequired(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    _ = context;
    if (value == null or trim(value.?).len == 0) {
        return "This field is required";
    }
    return null;
}

//
// Validates a name the user typed (`'Name is required'`).
//
fn validateName(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    _ = context;
    if (value == null or trim(value.?).len == 0) {
        return "Name is required";
    }
    return null;
}

//
// Validates a path the user typed (`'Path is required'`).
//
fn validatePath(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    _ = context;
    if (value == null or trim(value.?).len == 0) {
        return "Path is required";
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
// Prompts for a required text value and returns the trimmed string.
//
fn promptRequired(allocator: std.mem.Allocator, io: std.Io, message: []const u8) ![]const u8 {
    const value = try text(allocator, io, .{
        .message = message,
        .validate = .{
            .context = null,
            .function = validateRequired,
        },
    });

    if (isCancel(value)) {
        try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
        exit(io, 0);
    }

    return trim(value.value);
}

//
// Prompts for an optional text value and returns the trimmed string, or undefined if blank.
//
fn promptOptional(allocator: std.mem.Allocator, io: std.Io, message: []const u8) !?[]const u8 {
    const value = try text(allocator, io, .{
        .message = message,
    });

    if (isCancel(value)) {
        try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
        exit(io, 0);
    }

    const trimmed = trim(value.value);
    return if (trimmed.len > 0) trimmed else null;
}

// Not ported: dbsCommand (the command group is registered in index.zig with the Zig commander, like every other
// command).

//
// psi dbs list: table of all configured databases.
//
pub fn dbsList(allocator: std.mem.Allocator, io: std.Io) !void {
    const databases = try getDatabases(allocator, io);

    if (databases.len == 0) {
        log.info(try pc.yellow(allocator, "No databases configured."));
        log.info(try pc.dim(allocator, "Use \"psi dbs add\" to add a database."));
        return;
    }

    log.info(try pc.cyan(allocator, try format(allocator, "\n{s} Path", .{try padEnd(allocator, "Name", 25)})));
    log.info(try rule(allocator, 70));

    for (databases) |dbEntry| {
        log.info(try format(allocator, "{s} {s}", .{ try padEnd(allocator, dbEntry.name, 25), dbEntry.path }));
    }

    log.info("");
}

//
// psi dbs add: interactively add a new database entry.
//
pub fn dbsAdd(allocator: std.mem.Allocator, io: std.Io, cmdOptions: *IDbsAddOptions) !void {
    if (cmdOptions.yes orelse false) {
        if (!isGiven(cmdOptions.name) or !isGiven(cmdOptions.path)) {
            log.@"error"(try pc.red(allocator, "\u{2717} --name and --path are required with --yes"));
            exit(io, 1);
        }

        cmdOptions.name = trim(cmdOptions.name.?);
        cmdOptions.path = trim(cmdOptions.path.?);
        cmdOptions.encryptionKey = trimGiven(cmdOptions.encryptionKey);
        cmdOptions.s3Cred = trimGiven(cmdOptions.s3Cred);
        cmdOptions.geocodingKey = trimGiven(cmdOptions.geocodingKey);

        const entry: IDatabaseEntry = .{
            .name = cmdOptions.name.?,
            .description = if (isGiven(cmdOptions.description)) cmdOptions.description.? else "",
            .path = cmdOptions.path.?,
            .s3Key = cmdOptions.s3Cred,
            .encryptionKey = cmdOptions.encryptionKey,
            .geocodingKey = cmdOptions.geocodingKey,
        };

        if (try findDatabase(allocator, io, entry.name)) |existing| {
            log.@"error"(try pc.red(allocator, try format(allocator, "\u{2717} A database named \"{s}\" already exists ({s}). Use a different name or remove the existing entry first.", .{ entry.name, existing.path })));
            exit(io, 1);
        }

        try checkSecretsExist(allocator, io, cmdOptions.encryptionKey, cmdOptions.s3Cred, cmdOptions.geocodingKey);

        try addDatabaseEntry(allocator, io, entry);
        log.info(try pc.green(allocator, try format(allocator, "\u{2713} Database \"{s}\" added.", .{entry.name})));
        return;
    }

    try intro(io, try pc.cyan(allocator, "Add Database"), .{});

    const name = try promptRequired(allocator, io, "Database name:");
    const description = try promptOptional(allocator, io, "Description (optional):") orelse "";
    const dbPath = try promptRequired(allocator, io, "Database path (filesystem or S3):");

    if (try findDatabase(allocator, io, name)) |existing| {
        try outro(io, try pc.red(allocator, try format(allocator, "\u{2717} A database named \"{s}\" already exists ({s}). Use a different name or remove the existing entry first.", .{ name, existing.path })), .{});
        exit(io, 1);
    }

    // Secret linking
    const s3Key = try pickOrCreateSecret(allocator, io, "s3-credentials", name, null);
    const encryptionKey = try pickOrCreateSecret(allocator, io, "encryption-key", name, null);
    const geocodingKey = try pickOrCreateSecret(allocator, io, "api-key", name, null);

    const entry: IDatabaseEntry = .{
        .name = name,
        .description = description,
        .path = dbPath,
        .s3Key = s3Key,
        .encryptionKey = encryptionKey,
        .geocodingKey = geocodingKey,
    };

    try addDatabaseEntry(allocator, io, entry);

    try outro(io, try pc.green(allocator, try format(allocator, "\u{2713} Database \"{s}\" added.", .{name})), .{});
}

//
// The outcome of selectDatabase: the prompt was cancelled, or the entry whose path was picked (null when no entry has
// that path).
//
const IDatabaseSelection = union(enum) {
    // The prompt was cancelled (and "Cancelled." was said).
    cancelled,

    // The entry picked.
    picked: ?IDatabaseEntry,
};

//
// Picks one of the databases with a select prompt (the shared body of view, edit and remove when neither --name nor
// --path is given): `select` over `{ value: path, label: "name (path)" }`, then `databases.find` by the path.
//
fn selectDatabase(allocator: std.mem.Allocator, io: std.Io, databases: []const IDatabaseEntry, message: []const u8) !IDatabaseSelection {
    const options = try allocator.alloc(prompts.Option, databases.len);
    for (databases, 0..) |database, index| {
        options[index] = .{
            .value = database.path,
            .label = try format(allocator, "{s} ({s})", .{ database.name, database.path }),
        };
    }

    const selected = try select(allocator, io, .{
        .message = message,
        .options = options,
    });

    if (isCancel(selected)) {
        try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
        return .cancelled;
    }

    for (databases) |database| {
        if (std.mem.eql(u8, database.path, selected.value)) {
            return .{
                .picked = database,
            };
        }
    }
    return .{
        .picked = null,
    };
}

//
// psi dbs view [name]: show all fields of a database entry.
//
pub fn dbsView(allocator: std.mem.Allocator, io: std.Io, cmdOptions: *IDbsViewOptions) !void {
    var entry: ?IDatabaseEntry = null;

    if (!isGiven(cmdOptions.name) and !isGiven(cmdOptions.path)) {
        if (cmdOptions.yes orelse false) {
            log.@"error"(try pc.red(allocator, "\u{2717} --name or --path is required with --yes"));
            exit(io, 1);
        }

        const databases = try getDatabases(allocator, io);
        if (databases.len == 0) {
            log.info(try pc.yellow(allocator, "No databases configured."));
            return;
        }

        switch (try selectDatabase(allocator, io, databases, "Select a database to view:")) {
            .cancelled => {
                return;
            },
            .picked => |picked| {
                entry = picked;
            },
        }
    }
    else {
        entry = try findDatabaseByIdentifier(allocator, io, cmdOptions.name, cmdOptions.path);
    }

    const found = entry orelse {
        try exitNoMatchingDatabase(allocator, io, cmdOptions.name);
    };

    const none = try pc.dim(allocator, "(none)");
    log.info(try pc.cyan(allocator, "\nDatabase Entry"));
    log.info(try rule(allocator, 50));
    log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "Name:        "), found.name }));
    log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "Description: "), if (found.description.len > 0) found.description else none }));
    log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "Path:        "), found.path }));
    log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "S3 Creds:    "), if (isGiven(found.s3Key)) found.s3Key.? else none }));
    log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "Encryption:  "), if (isGiven(found.encryptionKey)) found.encryptionKey.? else none }));
    log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "Geocoding:   "), if (isGiven(found.geocodingKey)) found.geocodingKey.? else none }));

    if (isGiven(found.origin)) {
        log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "Origin:      "), found.origin.? }));
    }

    log.info("");
}

//
// psi dbs edit [name]: edit fields with current values pre-populated.
//
pub fn dbsEdit(allocator: std.mem.Allocator, io: std.Io, cmdOptions: *IDbsEditOptions) !void {
    var entry: ?IDatabaseEntry = null;

    if (!isGiven(cmdOptions.name)) {
        if (cmdOptions.yes orelse false) {
            log.@"error"(try pc.red(allocator, "\u{2717} --name is required with --yes"));
            exit(io, 1);
        }

        const databases = try getDatabases(allocator, io);
        if (databases.len == 0) {
            log.info(try pc.yellow(allocator, "No databases configured."));
            return;
        }

        switch (try selectDatabase(allocator, io, databases, "Select a database to edit:")) {
            .cancelled => {
                return;
            },
            .picked => |picked| {
                entry = picked;
            },
        }
    }
    else {
        entry = try findDatabase(allocator, io, cmdOptions.name.?);
    }

    const found = entry orelse {
        log.@"error"(try pc.red(allocator, try format(allocator, "\u{2717} No database named \"{s}\" found.", .{cmdOptions.name orelse "undefined"})));
        try logDidYouMean(allocator, try findSimilarDatabaseNames(allocator, io, cmdOptions.name orelse "undefined"));
        exit(io, 1);
    };

    if (cmdOptions.yes orelse false) {
        cmdOptions.name = trimGiven(cmdOptions.name);
        cmdOptions.newName = trimGiven(cmdOptions.newName);
        cmdOptions.path = trimGiven(cmdOptions.path);
        cmdOptions.encryptionKey = trimGiven(cmdOptions.encryptionKey);
        cmdOptions.s3Cred = trimGiven(cmdOptions.s3Cred);
        cmdOptions.geocodingKey = trimGiven(cmdOptions.geocodingKey);

        try checkSecretsExist(allocator, io, cmdOptions.encryptionKey, cmdOptions.s3Cred, cmdOptions.geocodingKey);

        const updated: IDatabaseEntry = .{
            .name = if (isGiven(cmdOptions.newName)) cmdOptions.newName.? else found.name,
            .description = cmdOptions.description orelse found.description,
            .path = if (isGiven(cmdOptions.path)) cmdOptions.path.? else found.path,
            .origin = found.origin,
            .s3Key = cmdOptions.s3Cred orelse found.s3Key,
            .encryptionKey = cmdOptions.encryptionKey orelse found.encryptionKey,
            .geocodingKey = cmdOptions.geocodingKey orelse found.geocodingKey,
        };

        try updateDatabaseEntry(allocator, io, found.name, updated);

        log.info(try pc.green(allocator, try format(allocator, "\u{2713} Database \"{s}\" updated.", .{updated.name})));
        return;
    }

    try intro(io, try pc.cyan(allocator, try format(allocator, "Edit Database: {s}", .{found.name})), .{});

    const newName = try text(allocator, io, .{
        .message = "Database name:",
        .initialValue = found.name,
        .validate = .{
            .context = null,
            .function = validateName,
        },
    });

    if (isCancel(newName)) {
        try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
        return;
    }

    const newDescription = try text(allocator, io, .{
        .message = "Description:",
        .initialValue = found.description,
    });

    if (isCancel(newDescription)) {
        try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
        return;
    }

    const newPath = try text(allocator, io, .{
        .message = "Database path:",
        .initialValue = found.path,
        .validate = .{
            .context = null,
            .function = validatePath,
        },
    });

    if (isCancel(newPath)) {
        try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
        return;
    }

    // Secret linking (with current selections highlighted).
    const updatedName = trim(newName.value);
    const s3Key = try pickOrCreateSecret(allocator, io, "s3-credentials", updatedName, found.s3Key);
    const encryptionKey = try pickOrCreateSecret(allocator, io, "encryption-key", updatedName, found.encryptionKey);
    const geocodingKey = try pickOrCreateSecret(allocator, io, "api-key", updatedName, found.geocodingKey);

    const updated: IDatabaseEntry = .{
        .name = updatedName,
        .description = trim(newDescription.value),
        .path = trim(newPath.value),
        .origin = found.origin,
        .s3Key = s3Key,
        .encryptionKey = encryptionKey,
        .geocodingKey = geocodingKey,
    };

    // updateDatabaseEntry handles both renames (rewrites the recents slot) and field
    // changes; the original name is the lookup key.
    try updateDatabaseEntry(allocator, io, found.name, updated);

    try outro(io, try pc.green(allocator, try format(allocator, "\u{2713} Database \"{s}\" updated.", .{updated.name})), .{});
}

//
// psi dbs remove [name]: remove a database entry after confirmation.
//
pub fn dbsRemove(allocator: std.mem.Allocator, io: std.Io, cmdOptions: *IDbsRemoveOptions) !void {
    var entry: ?IDatabaseEntry = null;

    if (!isGiven(cmdOptions.name) and !isGiven(cmdOptions.path)) {
        if (cmdOptions.yes orelse false) {
            log.@"error"(try pc.red(allocator, "\u{2717} --name or --path is required with --yes"));
            exit(io, 1);
        }

        const databases = try getDatabases(allocator, io);
        if (databases.len == 0) {
            log.info(try pc.yellow(allocator, "No databases configured."));
            return;
        }

        switch (try selectDatabase(allocator, io, databases, "Select a database to remove:")) {
            .cancelled => {
                return;
            },
            .picked => |picked| {
                entry = picked;
            },
        }
    }
    else {
        entry = try findDatabaseByIdentifier(allocator, io, cmdOptions.name, cmdOptions.path);
    }

    const found = entry orelse {
        try exitNoMatchingDatabase(allocator, io, cmdOptions.name);
    };

    if (!(cmdOptions.yes orelse false)) {
        const confirmed = try confirm(allocator, io, .{
            .message = try format(allocator, "Remove database \"{s}\" ({s})? This does not delete the database files.", .{ found.name, found.path }),
            .initialValue = false,
        });

        if (isCancel(confirmed) or !confirmed.value) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return;
        }
    }

    try removeDatabaseEntry(allocator, io, found.name);
    try outro(io, try pc.green(allocator, try format(allocator, "\u{2713} Database \"{s}\" removed from list.", .{found.name})), .{});
}

//
// psi dbs clear: remove all database entries after confirmation.
//
pub fn dbsClear(allocator: std.mem.Allocator, io: std.Io, cmdOptions: *IDbsClearOptions) !void {
    const databases = try getDatabases(allocator, io);

    if (databases.len == 0) {
        log.info(try pc.yellow(allocator, "No databases configured."));
        return;
    }

    if (!(cmdOptions.yes orelse false)) {
        log.info(try pc.cyan(allocator, "\nDatabases to be removed:"));
        for (databases) |dbEntry| {
            log.info(try format(allocator, "  {s} ({s})", .{ dbEntry.name, dbEntry.path }));
        }
        log.info("");

        const firstConfirm = try confirm(allocator, io, .{
            .message = try format(allocator, "Remove all {d} database(s) from the list? This does not delete database files.", .{databases.len}),
            .initialValue = false,
        });

        if (isCancel(firstConfirm) or !firstConfirm.value) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return;
        }

        const secondConfirm = try confirm(allocator, io, .{
            .message = "Are you sure? All database entries will be permanently removed from the list.",
            .initialValue = false,
        });

        if (isCancel(secondConfirm) or !secondConfirm.value) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return;
        }
    }

    for (databases) |dbEntry| {
        try removeDatabaseEntry(allocator, io, dbEntry.name);
    }

    try outro(io, try pc.green(allocator, try format(allocator, "\u{2713} Removed {d} database(s) from the list.", .{databases.len})), .{});
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
// Logs the fields of a database share payload under a heading (the shared display of send and receive).
//
fn logPayloadFields(allocator: std.mem.Allocator, heading: []const u8, payload: IDatabaseSharePayload) !void {
    log.info(try pc.cyan(allocator, heading));
    log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "  Name:        "), payload.name }));
    log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "  Description: "), if (payload.description.len > 0) payload.description else try pc.dim(allocator, "(none)") }));
    log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "  Path:        "), payload.path }));
    if (payload.s3Credentials) |s3Credentials| {
        log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "  S3 Creds:    "), s3Credentials.name }));
    }
    if (payload.encryptionKey) |encryptionKey| {
        log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "  Encryption:  "), encryptionKey.name }));
    }
    if (payload.geocodingKey) |geocodingKey| {
        log.info(try std.mem.concat(allocator, u8, &.{ try pc.cyan(allocator, "  Geocoding:   "), geocodingKey.name }));
    }
    log.info("");
}

//
// Asks whether to include (or import) each secret of a payload, clearing the ones declined (the shared secret
// confirmations of send and receive: the verb is "Include" or "Import"). Returns false when a prompt was cancelled
// (after saying so).
//
fn confirmPayloadSecrets(allocator: std.mem.Allocator, io: std.Io, payload: *IDatabaseSharePayload, verb: []const u8) !bool {
    if (payload.s3Credentials) |s3Credentials| {
        const includeS3 = try confirm(allocator, io, .{
            .message = try format(allocator, "{s} S3 credentials ({s})?", .{ verb, s3Credentials.name }),
            .initialValue = true,
        });
        if (isCancel(includeS3)) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return false;
        }
        if (!includeS3.value) {
            payload.s3Credentials = null;
        }
    }

    if (payload.encryptionKey) |encryptionKey| {
        const includeEnc = try confirm(allocator, io, .{
            .message = try format(allocator, "{s} encryption key ({s})?", .{ verb, encryptionKey.name }),
            .initialValue = true,
        });
        if (isCancel(includeEnc)) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return false;
        }
        if (!includeEnc.value) {
            payload.encryptionKey = null;
        }
    }

    if (payload.geocodingKey) |geocodingKey| {
        const includeGeo = try confirm(allocator, io, .{
            .message = try format(allocator, "{s} geocoding key ({s})?", .{ verb, geocodingKey.name }),
            .initialValue = true,
        });
        if (isCancel(includeGeo)) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return false;
        }
        if (!includeGeo.value) {
            payload.geocodingKey = null;
        }
    }

    return true;
}

//
// Lets the user edit the name, description and path of a payload (the shared field editing of send and receive).
// Returns false when a prompt was cancelled (after saying so).
//
fn editPayloadFields(allocator: std.mem.Allocator, io: std.Io, payload: *IDatabaseSharePayload) !bool {
    const editedName = try text(allocator, io, .{
        .message = "Database name:",
        .initialValue = payload.name,
        .validate = .{
            .context = null,
            .function = validateName,
        },
    });
    if (isCancel(editedName)) {
        try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
        return false;
    }
    payload.name = trim(editedName.value);

    const editedDescription = try text(allocator, io, .{
        .message = "Description:",
        .initialValue = payload.description,
    });
    if (isCancel(editedDescription)) {
        try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
        return false;
    }
    payload.description = trim(editedDescription.value);

    const editedPath = try text(allocator, io, .{
        .message = "Database path:",
        .initialValue = payload.path,
        .validate = .{
            .context = null,
            .function = validatePath,
        },
    });
    if (isCancel(editedPath)) {
        try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
        return false;
    }
    payload.path = trim(editedPath.value);

    return true;
}

//
// Converts a database share payload to the JSON object the sender sends (the object resolveDatabaseSharePayload
// builds, keys in its order, with the fields that are undefined left out as JSON.stringify leaves them out).
//
fn payloadToJson(allocator: std.mem.Allocator, payload: IDatabaseSharePayload) !std.json.Value {
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{
        .emit_null_optional_fields = false,
    });
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
}

//
// The SIGINT listener of `dbs send` (`() => { sender.cancel(); }`).
//
fn cancelSender(context: *anyopaque) void {
    const sender: *LanShareSender = @ptrCast(@alignCast(context));
    sender.cancel();
}

//
// The SIGINT listener of `dbs receive` (`() => { receiver.cancel(); }`).
//
fn cancelReceiver(context: *anyopaque) void {
    const receiver: *LanShareReceiver = @ptrCast(@alignCast(context));
    receiver.cancel();
}

//
// psi dbs send [name]: share a database config with secrets over the LAN.
//
pub fn dbsSend(allocator: std.mem.Allocator, io: std.Io, cmdOptions: *IDbsSendOptions) !void {
    try intro(io, try pc.cyan(allocator, "Send Database"), .{});

    const skipPrompts = cmdOptions.yes orelse false;

    try networkRequirementNote(allocator, io);

    var entry: IDatabaseEntry = undefined;

    if (isGiven(cmdOptions.name) or isGiven(cmdOptions.path)) {
        entry = try findDatabaseByIdentifier(allocator, io, cmdOptions.name, cmdOptions.path) orelse {
            try exitNoMatchingDatabase(allocator, io, cmdOptions.name);
        };
    }
    else {
        // Pick from configured databases
        const databases = try getDatabases(allocator, io);
        if (databases.len == 0) {
            log.info(try pc.yellow(allocator, "No databases configured."));
            log.info(try pc.dim(allocator, "Use \"psi dbs add\" to add a database first."));
            return;
        }

        const options = try allocator.alloc(prompts.Option, databases.len);
        for (databases, 0..) |dbEntry, index| {
            options[index] = .{
                .value = dbEntry.path,
                .label = dbEntry.name,
            };
        }

        const selected = try select(allocator, io, .{
            .message = "Select a database to send:",
            .options = options,
        });

        if (isCancel(selected)) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return;
        }

        var selectedEntry: ?IDatabaseEntry = null;
        for (databases) |dbEntry| {
            if (std.mem.eql(u8, dbEntry.path, selected.value)) {
                selectedEntry = dbEntry;
                break;
            }
        }
        entry = selectedEntry orelse {
            log.@"error"(try pc.red(allocator, "\u{2717} Database not found."));
            exit(io, 1);
        };
    }

    // Resolve the database payload with secrets
    var payload = try resolveDatabaseSharePayload(allocator, io, .{
        .name = entry.name,
        .description = entry.description,
        .path = entry.path,
        .origin = entry.origin,
        .s3Key = entry.s3Key,
        .encryptionKey = entry.encryptionKey,
        .geocodingKey = entry.geocodingKey,
    });

    // Display resolved fields
    try logPayloadFields(allocator, "\nDatabase to send:", payload);

    if (isLocalPath(payload.path)) {
        try note(
            allocator,
            io,
            "The database path is a local filesystem path.\nThis works if the other device has access to the same path (e.g. a shared network drive),\nbut will need updating if the path is specific to this machine.",
            try pc.yellow(allocator, "\u{26a0} Local Path"),
            .{},
        );
    }

    if (!skipPrompts) {
        // Allow editing fields
        if (!try editPayloadFields(allocator, io, &payload)) {
            return;
        }

        // Confirm which secrets to include
        if (!try confirmPayloadSecrets(allocator, io, &payload, "Include")) {
            return;
        }
    }

    // Create sender (generates or uses supplied pairing code)
    var sender = try LanShareSender.init(allocator, io, try payloadToJson(allocator, payload), cmdOptions.code);

    // Display the pairing code: the user must enter this on the other device
    log.info("");
    log.info(try pc.cyan(allocator, try format(allocator, "  Pairing code: {s}", .{try pc.bold(allocator, sender.pairingCode)})));
    log.info(try pc.dim(allocator, "  Enter this code on the other device, then wait."));
    log.info("");

    const spin = try spinner(allocator, io, !skipPrompts);
    try spin.start("Waiting for other device on local network... (Ctrl+C to cancel)");

    // TODO: this mirrors a bug in the TypeScript (dbs.ts dbsSend) until both are fixed. Ctrl+C is taken over only
    // after the pairing code and the waiting message are shown. A SIGINT that lands in between is not the command's
    // to handle: in a terminal it kills the process, but a process started as a background job of a shell without
    // job control inherits SIGINT as ignored (the smoke test pool starts every test that way, and the `set -m` of
    // the share-cancel tests does not reset an inherited ignore), so the signal is dropped and the sender waits out
    // its full 60 second discovery timeout holding UDP port 54321. That is the share-cancel hang of smoke test 78 on
    // macOS x64 in Release run 684 ("still running 20s after Ctrl+C"): the loaded runner stalled the sender between
    // writing "Pairing code" and installing the listener, and test 79 beside it took 1m03s because the stranded
    // sender took its receiver's loopback announcements until it exited. Reproduced on Linux by holding back the
    // SIGINT rt_sigaction with strace (--inject=rt_sigaction:delay_enter=3s:when=13): the sender ran on for 63
    // seconds after SIGINT, and exited in 0.1 seconds once the listener was registered before the code was logged.
    // Fix both CLIs by registering this listener before the pairing code is logged (and see the TODO on
    // LanShareSender.cancel for a cancel that comes before the wait).
    const sigintHandler: process_signals.ISignalListener = .{
        .context = &sender,
        .function = cancelSender,
    };
    try process_signals.on(.SIGINT, sigintHandler);

    const endpoint = try sender.waitForReceiver(io, 60000);
    try process_signals.removeListener(.SIGINT, sigintHandler);

    if (endpoint == null) {
        // Discovery now ignores receivers whose pairing code does not match, which stops two shares
        // hijacking each other but also means a mistyped code ends as a plain timeout. This tells
        // the two apart.
        //
        // A device that announced a different pairing code is a mistyped code, not an absent
        // device, and saying so saves the user hunting the wrong problem.
        if (sender.sawMismatchedReceiver) {
            try spin.stop(try pc.yellow(allocator, "Pairing code rejected: a device was found but it is using a different code."));
        }
        else {
            try spin.stop(try pc.yellow(allocator, "No device found within 60 seconds."));
        }
        return;
    }

    try spin.stop(try pc.green(allocator, "Device found!"));

    const success = try sender.send(endpoint.?);

    if (success) {
        try outro(io, try pc.green(allocator, "\u{2713} Database sent successfully!"), .{});
    }
    else {
        log.@"error"(try pc.red(allocator, "\u{2717} Pairing code rejected by other device."));
        exit(io, 1);
    }
}

//
// The state of the conflict resolver buildConflictResolver builds: whether to skip the prompts, and the Io the
// prompts use.
//
const IConflictResolverContext = struct {
    // True to reuse every existing secret without prompting.
    skipPrompts: bool,

    // The Io the prompts use.
    io: std.Io,
};

//
// The resolver function of buildConflictResolver (the arrow function in TypeScript).
//
fn resolveSecretConflict(context: ?*anyopaque, allocator: std.mem.Allocator, secretName: []const u8, secretType: []const u8) anyerror!IConflictResolution {
    const resolverContext: *IConflictResolverContext = @ptrCast(@alignCast(context.?));
    const io = resolverContext.io;

    if (resolverContext.skipPrompts) {
        log.info(try pc.yellow(allocator, try format(allocator, "  \u{26a0} Secret \"{s}\" already exists \u{2014} reusing existing.", .{secretName})));
        return .{
            .action = .reuse,
        };
    }

    log.info("");

    const choice = try select(allocator, io, .{
        .message = try format(allocator, "Secret \"{s}\" ({s}) already exists in your vault. What would you like to do?", .{ secretName, secretType }),
        .options = &.{
            .{
                .value = "reuse",
                .label = "Reuse existing \u{2014} skip importing this secret",
            },
            .{
                .value = "replace",
                .label = try format(allocator, "Replace existing \u{2014} \u{26a0} may break other databases that use \"{s}\"", .{secretName}),
            },
            .{
                .value = "rename",
                .label = "Save with a new name",
            },
        },
    });

    if (isCancel(choice)) {
        try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
        exit(io, 0);
    }

    if (std.mem.eql(u8, choice.value, "rename")) {
        const newName = try text(allocator, io, .{
            .message = "New secret name:",
            .initialValue = secretName,
            .validate = .{
                .context = null,
                .function = validateName,
            },
        });

        if (isCancel(newName)) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            exit(io, 0);
        }

        return .{
            .action = .rename,
            .newName = trim(newName.value),
        };
    }

    if (std.mem.eql(u8, choice.value, "replace")) {
        return .{
            .action = .replace,
        };
    }
    return .{
        .action = .reuse,
    };
}

//
// Builds a ConflictResolver for use during dbs receive.
// When skipPrompts is true the resolver logs a message and reuses the
// existing secret without prompting.  Otherwise it presents an interactive
// menu offering replace, reuse, or rename.
//
fn buildConflictResolver(allocator: std.mem.Allocator, io: std.Io, skipPrompts: bool) !ConflictResolver {
    const resolverContext = try allocator.create(IConflictResolverContext);
    resolverContext.* = .{
        .skipPrompts = skipPrompts,
        .io = io,
    };
    return .{
        .context = resolverContext,
        .function = resolveSecretConflict,
    };
}

//
// Converts the payload a receiver got to the database share payload (the `rawPayload as IDatabaseSharePayload` of
// TypeScript). A payload without the fields a database share has is thrown as an error.
//
fn toDatabaseSharePayload(allocator: std.mem.Allocator, rawPayload: std.json.Value) !IDatabaseSharePayload {
    return std.json.parseFromValueLeaky(IDatabaseSharePayload, allocator, rawPayload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        return utils.errors.throwError("The received payload is not a database share ({s}).", .{@errorName(err)});
    };
}

//
// psi dbs receive: receive a database config with secrets from another device.
//
pub fn dbsReceive(allocator: std.mem.Allocator, io: std.Io, cmdOptions: *IDbsReceiveOptions) !void {
    try intro(io, try pc.cyan(allocator, "Receive Database"), .{});

    const skipPrompts = cmdOptions.yes orelse false;

    try networkRequirementNote(allocator, io);

    log.info(try pc.dim(allocator, "Hint: Run `psi dbs send` on another device to send a database."));

    var code: []const u8 = undefined;

    if (skipPrompts) {
        if (!isGiven(cmdOptions.code)) {
            log.@"error"(try pc.red(allocator, "\u{2717} --code is required with --yes"));
            exit(io, 1);
        }
        code = cmdOptions.code.?;
    }
    else {
        const codeInput = try text(allocator, io, .{
            .message = "Enter the 4-digit pairing code shown on the other device:",
            .validate = .{
                .context = null,
                .function = validatePairingCode,
            },
        });

        if (isCancel(codeInput)) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return;
        }

        code = trim(codeInput.value);
    }

    var receiver = LanShareReceiver.init(io, 60000);
    defer receiver.deinit();
    try receiver.start(code);

    const spin = try spinner(allocator, io, !skipPrompts);
    try spin.start("Waiting for sender on the local network... (Ctrl+C to cancel)");

    // TODO: this mirrors the TypeScript (dbs.ts dbsReceive) until both are fixed: the share-cancel hang explained at
    // the TODO in dbsSend. Ctrl+C is taken over only after the waiting message is shown, as
    // the TypeScript does, so a SIGINT between the two is lost when SIGINT was inherited as ignored.
    const sigintHandler: process_signals.ISignalListener = .{
        .context = &receiver,
        .function = cancelReceiver,
    };
    try process_signals.on(.SIGINT, sigintHandler);

    const rawPayload = try receiver.receive();
    try process_signals.removeListener(.SIGINT, sigintHandler);

    if (rawPayload == null) {
        try spin.stop(try pc.yellow(allocator, "No device connected within 60 seconds."));
        return;
    }

    try spin.stop(try pc.green(allocator, "Payload received!"));

    var payload = try toDatabaseSharePayload(allocator, rawPayload.?);

    // Display received fields
    try logPayloadFields(allocator, "\nReceived database:", payload);

    if (isLocalPath(payload.path)) {
        try note(
            allocator,
            io,
            "The database path is a local filesystem path from the other device.\nThis works if you have access to the same path (e.g. a shared network drive),\nbut you may need to update it if the path is specific to their machine.",
            try pc.yellow(allocator, "\u{26a0} Local Path"),
            .{},
        );
    }

    if (!skipPrompts) {
        // Allow editing fields before saving
        if (!try editPayloadFields(allocator, io, &payload)) {
            return;
        }

        // Confirm which secrets to import
        if (!try confirmPayloadSecrets(allocator, io, &payload, "Import")) {
            return;
        }
    }

    // Resolve any database-name collision before importing.
    const resolution = try resolveDatabaseNameConflict(allocator, io, payload.name, skipPrompts) orelse {
        return;
    };
    payload.name = resolution.finalName;
    if (resolution.replaceExisting) |replaceExisting| {
        try removeDatabaseEntry(allocator, io, replaceExisting);
    }

    // Import the payload
    const dbEntry = try importDatabasePayload(allocator, io, payload, try buildConflictResolver(allocator, io, skipPrompts));
    try addDatabaseEntry(allocator, io, .{
        .name = dbEntry.name,
        .description = dbEntry.description,
        .path = dbEntry.path,
        .origin = dbEntry.origin,
        .s3Key = dbEntry.s3Key,
        .encryptionKey = dbEntry.encryptionKey,
        .geocodingKey = dbEntry.geocodingKey,
    });

    try outro(io, try pc.green(allocator, try format(allocator, "\u{2713} Database \"{s}\" imported successfully!", .{dbEntry.name})), .{});
}

//
// Outcome of resolving a database-name conflict during dbs receive.
//
const IDatabaseNameResolution = struct {
    // The name to use for the imported database (may differ from the original on rename).
    finalName: []const u8,

    // The existing entry name to remove first, if Replace was chosen.
    replaceExisting: ?[]const u8,
};

//
// Checks whether the proposed database name collides with an existing entry. When it does,
// prompts the user to Replace, Rename, or Cancel. Returns undefined when the user cancels
// (caller should print its own outro and return). In --skip-prompts mode, errors out on
// any collision rather than silently overwriting.
//
fn resolveDatabaseNameConflict(allocator: std.mem.Allocator, io: std.Io, proposedName: []const u8, skipPrompts: bool) !?IDatabaseNameResolution {
    const collision = try findDatabase(allocator, io, proposedName) orelse {
        return .{
            .finalName = proposedName,
            .replaceExisting = null,
        };
    };

    if (skipPrompts) {
        log.@"error"(try pc.red(allocator, try format(allocator, "\u{2717} A database named \"{s}\" already exists ({s}). Use a different name or remove the existing entry first.", .{ proposedName, collision.path })));
        exit(io, 1);
    }

    log.info("");
    const choice = try select(allocator, io, .{
        .message = try format(allocator, "A database named \"{s}\" already exists ({s}). What would you like to do?", .{ proposedName, collision.path }),
        .options = &.{
            .{
                .value = "replace",
                .label = "Replace existing \u{2014} removes the existing entry then imports the new one",
            },
            .{
                .value = "rename",
                .label = "Save with a different name",
            },
            .{
                .value = "cancel",
                .label = "Cancel",
            },
        },
    });

    if (isCancel(choice) or std.mem.eql(u8, choice.value, "cancel")) {
        try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
        return null;
    }

    if (std.mem.eql(u8, choice.value, "replace")) {
        return .{
            .finalName = proposedName,
            .replaceExisting = collision.name,
        };
    }

    // Rename: loop until the user provides a unique name or cancels.
    while (true) {
        const renamed = try text(allocator, io, .{
            .message = "New database name:",
            .initialValue = proposedName,
            .validate = .{
                .context = null,
                .function = validateName,
            },
        });
        if (isCancel(renamed)) {
            try outro(io, try pc.yellow(allocator, "Cancelled."), .{});
            return null;
        }
        const trimmed = trim(renamed.value);
        const stillCollides = try findDatabase(allocator, io, trimmed);
        if (stillCollides == null) {
            return .{
                .finalName = trimmed,
                .replaceExisting = null,
            };
        }
        log.@"error"(try pc.red(allocator, try format(allocator, "\u{2717} A database named \"{s}\" already exists. Choose a different name.", .{trimmed})));
    }
}
