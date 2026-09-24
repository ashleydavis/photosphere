const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const storage_zig = @import("storage-zig");
const encryption = @import("encryption-zig");
const vault_zig = @import("vault-zig");
const fuzzy_match = @import("fuzzy-match-zig");
const task_queue = @import("task-queue-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const bdb = @import("bdb-zig");
const node_api = @import("node-api-zig");
const pc = @import("picocolors.zig");
const directory_picker = @import("directory-picker.zig");
const ensure_tools = @import("ensure-tools.zig");
const prompts = @import("clack/prompts.zig");
const log_module = @import("log.zig");
const worker_pool = @import("worker-pool.zig");
const IS3Credentials = storage_zig.cloud_storage.IS3Credentials;
const IStorage = storage_zig.storage.IStorage;
const createStorage = storage_zig.storage_factory.createStorage;
const pathJoin = storage_zig.storage_factory.pathJoin;
const loadEncryptionKeysFromPem = encryption.key_utils.loadEncryptionKeysFromPem;
const IDatabaseEntry = node_api.databases_config.IDatabaseEntry;
const getDatabases = node_api.databases_config.getDatabases;
const createMediaFileDatabase = node_api.media_file_database.createMediaFileDatabase;
const loadSortIndexes = node_api.media_file_database.loadSortIndexes;
const CURRENT_DATABASE_VERSION = merkle_tree_zig.merkle_tree.CURRENT_DATABASE_VERSION;
const loadTreeVersion = merkle_tree_zig.merkle_tree.loadTreeVersion;
const BsonDatabase = bdb.database.BsonDatabase;
const IBsonCollection = bdb.collection.IBsonCollection;
const getDirectoryForCommand = directory_picker.getDirectoryForCommand;
const ensureMediaProcessingTools = ensure_tools.ensureMediaProcessingTools;
const IEncryptionKeyPem = encryption.key_utils.IEncryptionKeyPem;
const generateKeyPair = encryption.key_utils.generateKeyPair;
const exportPublicKeyToPem = encryption.key_utils.exportPublicKeyToPem;
const createPrivateKey = encryption.node_crypto.createPrivateKey;
const createPublicKey = encryption.node_crypto.createPublicKeyFromPrivateKey;
const exportPrivateKey = encryption.node_crypto.exportPrivateKey;
const getVault = vault_zig.get_vault.getVault;
const getDefaultVaultType = vault_zig.get_vault.getDefaultVaultType;
const fuzzyMatch = fuzzy_match.fuzzy_match.fuzzyMatch;
const IQueueBackend = task_queue.queue_backend.IQueueBackend;
const setQueueBackend = task_queue.queue_backend.setQueueBackend;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;
const RandomUuidGenerator = utils.random_uuid_generator.RandomUuidGenerator;
const TimestampProvider = utils.timestamp_provider.TimestampProvider;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;
const TestTimestampProvider = node_utils.test_timestamp_provider.TestTimestampProvider;
const WorkerPoolBun = worker_pool.WorkerPoolBun;
const configureLog = log_module.configureLog;
const exit = node_utils.termination.exit;
const registerTerminationCallback = node_utils.termination.registerTerminationCallback;
const getProcessTmpDir = node_utils.fs.getProcessTmpDir;
const log = &utils.log.log;
const confirm = prompts.confirm;
const text = prompts.text;
const password = prompts.password;
const isCancel = prompts.isCancel;
const outro = prompts.outro;
const select = prompts.select;
const multiline = prompts.multiline;

//
// Gets a string field of a parsed JSON object, or null when it is missing or not a string.
//
fn jsonString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

//
// Converts the JSON of a stored S3 credentials secret to IS3Credentials
// (TypeScript: `{ region: parsed.region, accessKeyId: parsed.accessKeyId, ... }`).
//
fn parseS3Credentials(allocator: std.mem.Allocator, json: []const u8) !IS3Credentials {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
    const object = switch (parsed) {
        .object => |object| object,
        else => return .{ .region = null, .accessKeyId = "", .secretAccessKey = "", .endpoint = null },
    };
    return .{
        .region = jsonString(object, "region"),
        .accessKeyId = jsonString(object, "accessKeyId") orelse "",
        .secretAccessKey = jsonString(object, "secretAccessKey") orelse "",
        .endpoint = jsonString(object, "endpoint"),
    };
}

//
// Reads the default S3 credentials fallback from the vault.
//
pub fn getDefaultS3Config(allocator: std.mem.Allocator, io: std.Io) !?IS3Credentials {
    const vault = try getVault(getDefaultVaultType());
    const secret = try vault.get(allocator, io, "default:s3") orelse return null;
    return try parseS3Credentials(allocator, secret.value);
}

// Not ported: resolveGeocodingApiKey (not used by replicate or verify).

//
// Validates the S3 endpoint.
//
fn validateEndpoint(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    _ = context;
    if (value) |endpoint| {
        if (endpoint.len > 0 and !std.mem.startsWith(u8, endpoint, "http://") and !std.mem.startsWith(u8, endpoint, "https://")) {
            return "Endpoint must start with http:// or https://";
        }
    }
    return null;
}

//
// Validates the S3 region.
//
fn validateRegion(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    _ = context;
    const region = value orelse return "Region is required";
    if (std.mem.trim(u8, region, " \t\r\n").len == 0) {
        return "Region is required";
    }
    return null;
}

//
// Validates the S3 access key id.
//
fn validateAccessKeyId(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    _ = context;
    const accessKeyId = value orelse return "Access Key ID is required";
    if (std.mem.trim(u8, accessKeyId, " \t\r\n").len == 0) {
        return "Access Key ID is required";
    }
    return null;
}

//
// Validates the S3 secret access key.
//
fn validateSecretAccessKey(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    _ = context;
    const secretAccessKey = value orelse return "Secret Access Key is required";
    if (std.mem.trim(u8, secretAccessKey, " \t\r\n").len == 0) {
        return "Secret Access Key is required";
    }
    return null;
}

//
// The JSON form of stored S3 credentials (JSON.stringify(credentials): the endpoint only when set).
//
const IStoredS3Credentials = struct {
    // The region.
    region: []const u8,

    // The access key id.
    accessKeyId: []const u8,

    // The secret access key.
    secretAccessKey: []const u8,

    // The endpoint, omitted when not set.
    endpoint: ?[]const u8 = null,
};

//
// Prompts the user to configure S3 credentials and stores them in the vault as a named secret.
// Returns the configured credentials, or undefined if AWS env vars are already set.
//
pub fn configureS3IfNeeded(allocator: std.mem.Allocator, io: std.Io, nonInteractive: bool) !?IS3Credentials {
    const accessKeyIdEnv = node_utils.process_env.getEnv("AWS_ACCESS_KEY_ID") orelse "";
    const secretAccessKeyEnv = node_utils.process_env.getEnv("AWS_SECRET_ACCESS_KEY") orelse "";
    if (accessKeyIdEnv.len > 0 and secretAccessKeyEnv.len > 0) {
        return null;
    }

    const existing = try getDefaultS3Config(allocator, io);
    if (existing) |credentials| {
        return credentials;
    }

    if (nonInteractive) {
        log.@"error"(try pc.red(allocator, "\u{2717} S3 credentials are required. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables, or run interactively to configure credentials."));
        exit(io, 1);
    }

    log.info(try pc.yellow(allocator, "\nNo S3 credentials found."));
    const shouldConfigure = try confirm(allocator, io, .{
        .message = "Would you like to configure S3 credentials now?",
        .initialValue = true,
    });

    if (isCancel(shouldConfigure) or !shouldConfigure.value) {
        log.@"error"(try pc.red(allocator, "S3 credentials are required."));
        exit(io, 1);
    }

    log.info(try pc.cyan(allocator, "Your credentials will be stored securely in your OS keychain as 'default:s3'."));

    const endpoint = try text(allocator, io, .{
        .message = "S3 Endpoint URL (leave empty for AWS S3):",
        .placeholder = "https://nyc3.digitaloceanspaces.com",
        .validate = .{ .context = null, .function = validateEndpoint },
    });

    if (isCancel(endpoint)) {
        exit(io, 0);
    }

    const region = try text(allocator, io, .{
        .message = "Region:",
        .initialValue = "us-east-1",
        .validate = .{ .context = null, .function = validateRegion },
    });

    if (isCancel(region)) {
        exit(io, 0);
    }

    const accessKeyId = try text(allocator, io, .{
        .message = "Access Key ID:",
        .validate = .{ .context = null, .function = validateAccessKeyId },
    });

    if (isCancel(accessKeyId)) {
        exit(io, 0);
    }

    const secretAccessKey = try password(allocator, io, .{
        .message = "Secret Access Key:",
        .validate = .{ .context = null, .function = validateSecretAccessKey },
    });

    if (isCancel(secretAccessKey)) {
        exit(io, 0);
    }

    var credentials: IS3Credentials = .{
        .region = std.mem.trim(u8, region.value, " \t\r\n"),
        .accessKeyId = std.mem.trim(u8, accessKeyId.value, " \t\r\n"),
        .secretAccessKey = std.mem.trim(u8, secretAccessKey.value.?, " \t\r\n"),
        .endpoint = null,
    };

    const endpointStr = std.mem.trim(u8, endpoint.value, " \t\r\n");
    if (endpointStr.len > 0) {
        credentials.endpoint = endpointStr;
    }

    const vault = try getVault(getDefaultVaultType());
    const stored: IStoredS3Credentials = .{
        .region = credentials.region.?,
        .accessKeyId = credentials.accessKeyId,
        .secretAccessKey = credentials.secretAccessKey,
        .endpoint = credentials.endpoint,
    };
    try vault.set(allocator, io, .{
        .name = "default:s3",
        .type = "s3-credentials",
        .value = try std.json.Stringify.valueAlloc(allocator, stored, .{ .emit_null_optional_fields = false }),
    });

    return credentials;
}

//
// Lists vault key names for all encryption keys stored in the vault.
//
pub fn getAvailableKeys(allocator: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    const vault = try getVault(getDefaultVaultType());
    const secrets = try vault.list(allocator, io);
    var names: std.ArrayList([]const u8) = .empty;
    for (secrets) |secret| {
        if (std.mem.eql(u8, secret.type, "encryption-key")) {
            try names.append(allocator, secret.name);
        }
    }
    return names.items;
}

//
// Prompts the user to pick an encryption key from those stored in the vault.
//
pub fn selectEncryptionKey(allocator: std.mem.Allocator, io: std.Io, message: []const u8) ![]const u8 {
    const keyNames = try getAvailableKeys(allocator, io);

    if (keyNames.len == 0) {
        try outro(io, try pc.red(allocator, "\u{2717} No encryption keys found.\n  Use \"psi secrets add\" to add a key or \"psi secrets import\" to import an existing key file."), .{});
        exit(io, 1);
    }

    var options: std.ArrayList(prompts.Option) = .empty;
    for (keyNames) |name| {
        try options.append(allocator, .{
            .value = name,
            .label = name,
        });
    }
    const selectedKey = try select(allocator, io, .{
        .message = message,
        .options = options.items,
    });

    if (isCancel(selectedKey)) {
        exit(io, 1);
    }

    return selectedKey.value;
}

//
// Result of encryption prompting.
//
pub const IEncryptionPromptResult = struct {
    // Vault key name (e.g. "my-photos").
    keyName: ?[]const u8 = null,

    // True when a new key pair should be generated and stored in the vault.
    generateKey: ?bool = null,
};

//
// Validates the name of a new encryption key.
//
fn validateKeyName(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    _ = context;
    const keyName = value orelse return "Key name is required";
    if (std.mem.trim(u8, keyName, " \t\r\n").len == 0) {
        return "Key name is required";
    }
    for (keyName) |character| {
        const allowed = std.ascii.isAlphanumeric(character) or character == '.' or character == '_' or character == '-';
        if (!allowed) {
            return "Key name can only contain letters, numbers, dots, hyphens, and underscores";
        }
    }
    return null;
}

//
// Generates a new RSA-4096 key pair and returns the private key as PKCS#8 PEM
// (TypeScript: `generateKeyPair().privateKey.export({ type: 'pkcs8', format: 'pem' })`).
//
fn generatePrivateKeyPem(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const keyPair = try generateKeyPair(allocator, io);
    return exportPrivateKey(allocator, keyPair.privateKey, .pem);
}

//
// Prompts for encryption settings. Either selects an existing vault key or
// generates a new RSA-4096 key pair and stores it in the vault.
// (TypeScript default message: 'Would you like to encrypt your database?'.)
//
pub fn promptForEncryption(allocator: std.mem.Allocator, io: std.Io, message: []const u8) !IEncryptionPromptResult {
    const wantEncryption = try confirm(allocator, io, .{
        .message = message,
        .initialValue = false,
    });

    if (isCancel(wantEncryption)) {
        exit(io, 1);
    }

    if (!wantEncryption.value) {
        return .{};
    }

    log.info(try pc.yellow(allocator, "\n\u{26A0}\u{FE0F} To encrypt your database you need a private key that you will have to keep safe and not lose\n   (otherwise you'll lose access to your encrypted database)"));

    // Ask how they want to handle the key
    const keyChoice = try select(allocator, io, .{
        .message = "How would you like to handle the encryption key?",
        .options = &.{
            .{ .value = "existing", .label = "Use an existing key" },
            .{ .value = "generate", .label = "Generate a new key" },
        },
    });

    if (isCancel(keyChoice)) {
        exit(io, 1);
    }

    if (std.mem.eql(u8, keyChoice.value, "existing")) {
        const selectedKey = try selectEncryptionKey(allocator, io, "Select an encryption key:");
        return .{ .keyName = selectedKey, .generateKey = false };
    }
    else if (std.mem.eql(u8, keyChoice.value, "generate")) {
        const keyNameInput = try text(allocator, io, .{
            .message = "Enter a name for the new encryption key:",
            .placeholder = "my-photos",
            .initialValue = "my-photos",
            .validate = .{ .context = null, .function = validateKeyName },
        });

        if (isCancel(keyNameInput)) {
            exit(io, 1);
        }

        const keyName = std.mem.trim(u8, keyNameInput.value, " \t\r\n");
        const privateKeyPem = try generatePrivateKeyPem(allocator, io);

        const vault = try getVault(getDefaultVaultType());
        try vault.set(allocator, io, .{
            .name = keyName,
            .type = "encryption-key",
            .value = privateKeyPem,
        });

        log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "\u{2713} Encryption key \"{s}\" stored.", .{keyName})));

        return .{ .keyName = keyName, .generateKey = true };
    }

    return .{};
}

//
// Resolves a comma-separated list of vault key names to PEM key pairs for use in storage descriptors.
// Returns an empty array if no key names are provided.
//
pub fn resolveKeyPems(allocator: std.mem.Allocator, io: std.Io, keyNames: ?[]const u8) ![]const IEncryptionKeyPem {
    const names_text = keyNames orelse return &.{};
    if (names_text.len == 0) {
        return &.{};
    }
    var pairs: std.ArrayList(IEncryptionKeyPem) = .empty;
    var name_iterator = std.mem.splitScalar(u8, names_text, ',');
    while (name_iterator.next()) |untrimmed| {
        const name = std.mem.trim(u8, untrimmed, " \t\r\n");
        if (name.len == 0) {
            continue;
        }
        const pair = try loadKeyPairFromVault(allocator, io, name);
        if (pair) |keyPair| {
            try pairs.append(allocator, keyPair);
        }
    }
    return pairs.items;
}

//
// Loads a PEM key pair from the vault for the given key name.
// Returns the pair or undefined if not found.
//
fn loadKeyPairFromVault(allocator: std.mem.Allocator, io: std.Io, keyName: []const u8) !?IEncryptionKeyPem {
    const vault = try getVault(getDefaultVaultType());
    const secret = try vault.get(allocator, io, keyName) orelse return null;
    if (!std.mem.eql(u8, secret.type, "encryption-key")) {
        return null;
    }
    const privateKeyPem = secret.value;
    const privateKeyObj = try createPrivateKey(allocator, privateKeyPem);
    const publicKeyPem = try exportPublicKeyToPem(allocator, createPublicKey(privateKeyObj));
    return .{ .privateKeyPem = privateKeyPem, .publicKeyPem = publicKeyPem };
}

//
// Builds an IEncryptionKeyPem from a private key PEM string and stores it in the vault.
//
fn buildAndStoreKeyPem(allocator: std.mem.Allocator, io: std.Io, keyName: []const u8, privateKeyPem: []const u8) !IEncryptionKeyPem {
    const vault = try getVault(getDefaultVaultType());
    try vault.set(allocator, io, .{ .name = keyName, .type = "encryption-key", .value = privateKeyPem });
    const privateKeyObj = try createPrivateKey(allocator, privateKeyPem);
    const publicKeyPem = try exportPublicKeyToPem(allocator, createPublicKey(privateKeyObj));
    return .{ .privateKeyPem = privateKeyPem, .publicKeyPem = publicKeyPem };
}

//
// Reads a PEM file (`fs.readFile(path, 'utf-8')`).
//
fn readPemFile(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
}

//
// Interactively prompts the user to add a missing encryption key (paste PEM or import from file).
// Returns undefined when non-interactive or cancelled.
//
pub fn promptToAddKey(allocator: std.mem.Allocator, io: std.Io, keyName: []const u8, nonInteractive: bool) !?IEncryptionKeyPem {
    if (nonInteractive) {
        return null;
    }

    const choice = try select(allocator, io, .{
        .message = try std.fmt.allocPrint(allocator, "Encryption key \"{s}\" was not found. How would you like to add it?", .{keyName}),
        .options = &.{
            .{ .value = "paste", .label = "Paste PEM" },
            .{ .value = "import", .label = "Import from file" },
            .{ .value = "cancel", .label = "Cancel" },
        },
    });

    if (isCancel(choice) or std.mem.eql(u8, choice.value, "cancel")) {
        return null;
    }

    if (std.mem.eql(u8, choice.value, "paste")) {
        const pem = try multiline(allocator, io, .{ .message = "Paste the private key PEM:" });
        if (isCancel(pem)) {
            return null;
        }
        return try buildAndStoreKeyPem(allocator, io, keyName, pem.value);
    }

    if (std.mem.eql(u8, choice.value, "import")) {
        const filePath = try text(allocator, io, .{ .message = "Enter the path to the PEM file:" });
        if (isCancel(filePath)) {
            return null;
        }
        const pem = try readPemFile(allocator, io, std.mem.trim(u8, filePath.value, " \t\r\n"));
        return try buildAndStoreKeyPem(allocator, io, keyName, pem);
    }

    return null;
}

//
// Interactively prompts the user to generate a new key, paste a PEM, or import from file.
// Returns undefined when non-interactive or cancelled.
//
pub fn promptToGenerateOrAddKey(allocator: std.mem.Allocator, io: std.Io, keyName: []const u8, nonInteractive: bool) !?IEncryptionKeyPem {
    if (nonInteractive) {
        return null;
    }

    const choice = try select(allocator, io, .{
        .message = try std.fmt.allocPrint(allocator, "Encryption key \"{s}\" was not found. How would you like to add it?", .{keyName}),
        .options = &.{
            .{ .value = "generate", .label = "Generate a new key" },
            .{ .value = "paste", .label = "Paste PEM" },
            .{ .value = "import", .label = "Import from file" },
            .{ .value = "cancel", .label = "Cancel" },
        },
    });

    if (isCancel(choice) or std.mem.eql(u8, choice.value, "cancel")) {
        return null;
    }

    if (std.mem.eql(u8, choice.value, "generate")) {
        const privateKeyPem = try generatePrivateKeyPem(allocator, io);
        return try buildAndStoreKeyPem(allocator, io, keyName, privateKeyPem);
    }

    if (std.mem.eql(u8, choice.value, "paste")) {
        const pem = try multiline(allocator, io, .{ .message = "Paste the private key PEM:" });
        if (isCancel(pem)) {
            return null;
        }
        return try buildAndStoreKeyPem(allocator, io, keyName, pem.value);
    }

    if (std.mem.eql(u8, choice.value, "import")) {
        const filePath = try text(allocator, io, .{ .message = "Enter the path to the PEM file:" });
        if (isCancel(filePath)) {
            return null;
        }
        const pem = try readPemFile(allocator, io, std.mem.trim(u8, filePath.value, " \t\r\n"));
        return try buildAndStoreKeyPem(allocator, io, keyName, pem);
    }

    return null;
}

//
// Resolves key PEMs by name. When the key is not found in the vault and a
// name was provided, the user is prompted to add the key (or generate one
// when canGenerate is true). Returns the resolved or newly-added key pems,
// or an empty array when the user cancels or non-interactive mode is active.
//
pub fn resolveKeyPemsWithPrompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    keyName: ?[]const u8,
    nonInteractive: bool,
    canGenerate: bool,
) ![]const IEncryptionKeyPem {
    const keyPems = try resolveKeyPems(allocator, io, keyName);
    const name = keyName orelse return keyPems;
    if (keyPems.len > 0 or name.len == 0) {
        return keyPems;
    }
    const newPair = if (canGenerate)
        try promptToGenerateOrAddKey(allocator, io, name, nonInteractive)
    else
        try promptToAddKey(allocator, io, name, nonInteractive);
    const pair = newPair orelse return &.{};
    const result = try allocator.alloc(IEncryptionKeyPem, 1);
    result[0] = pair;
    return result;
}

//
// Secrets resolved from a database entry in databases.json.
//
pub const IResolvedDatabaseSecrets = struct {
    // S3 credentials resolved from the linked shared secret.
    s3Config: ?IS3Credentials = null,

    // Vault key name for the encryption key pair linked to this database entry.
    encryptionKeyName: ?[]const u8 = null,

    // Vault key name for the Google geocoding API key linked to this database entry.
    geocodingKeyName: ?[]const u8 = null,
};

//
// Resolves a --db value to a database entry from databases.json.
// Tries exact path match first, then case-insensitive name match.
// Returns undefined if no match is found (not an error - the value is treated as a raw path).
// Errors if multiple entries match by name (ambiguous).
//
pub fn resolveDatabaseEntry(allocator: std.mem.Allocator, io: std.Io, dbValue: []const u8) !?IDatabaseEntry {
    const databases = try getDatabases(allocator, io);

    // Try exact path match first.
    for (databases) |dbEntry| {
        if (std.mem.eql(u8, dbEntry.path, dbValue)) {
            return dbEntry;
        }
    }

    // Try case-insensitive name match.
    var nameMatches: std.ArrayList(IDatabaseEntry) = .empty;
    for (databases) |dbEntry| {
        if (std.ascii.eqlIgnoreCase(dbEntry.name, dbValue)) {
            try nameMatches.append(allocator, dbEntry);
        }
    }

    if (nameMatches.items.len == 0) {
        return null;
    }

    if (nameMatches.items.len > 1) {
        log.@"error"(try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} Ambiguous database name \"{s}\" \u{2014} matches {d} entries:", .{ dbValue, nameMatches.items.len })));
        for (nameMatches.items) |match| {
            log.@"error"(try std.fmt.allocPrint(allocator, "  \u{2022} {s} \u{2192} {s}", .{ match.name, match.path }));
        }
        exit(io, 1);
    }

    return nameMatches.items[0];
}

//
// Returns registered database names whose edit distance from dbValue is within
// the fuzzy threshold. Used to suggest alternatives in "No database found" errors.
//
pub fn findSimilarDatabaseNames(allocator: std.mem.Allocator, io: std.Io, dbValue: []const u8) ![]const []const u8 {
    const databases = try getDatabases(allocator, io);
    var names: std.ArrayList([]const u8) = .empty;
    for (databases) |dbEntry| {
        try names.append(allocator, dbEntry.name);
    }
    return fuzzyMatch(allocator, dbValue, names.items);
}

//
// Returns vault secret names whose edit distance from secretName is within the
// fuzzy threshold. When type is provided only secrets of that type are considered.
// Used to suggest alternatives in "No secret found" errors.
//
pub fn findSimilarSecretNames(allocator: std.mem.Allocator, io: std.Io, secretName: []const u8, @"type": ?[]const u8) ![]const []const u8 {
    const vault = try getVault(getDefaultVaultType());
    const secrets = try vault.list(allocator, io);
    var names: std.ArrayList([]const u8) = .empty;
    for (secrets) |secret| {
        if (@"type") |secretType| {
            if (!std.mem.eql(u8, secret.type, secretType)) {
                continue;
            }
        }
        try names.append(allocator, secret.name);
    }
    return fuzzyMatch(allocator, secretName, names.items);
}

//
// Returns encryption-key secret names whose edit distance from keyName is within
// the fuzzy threshold. Thin wrapper around findSimilarSecretNames with type='encryption-key'.
//
pub fn findSimilarKeyNames(allocator: std.mem.Allocator, io: std.Io, keyName: []const u8) ![]const []const u8 {
    return findSimilarSecretNames(allocator, io, keyName, "encryption-key");
}

//
// Resolves vault secrets linked to a database entry.
// S3 credentials are only fetched when the entry path uses the s3: scheme.
// Encryption and geocoding key names are returned without vault access - the
// caller fetches them lazily when the secret is actually needed.
//
pub fn resolveSecretsFromEntry(allocator: std.mem.Allocator, io: std.Io, entry: IDatabaseEntry) !IResolvedDatabaseSecrets {
    var result: IResolvedDatabaseSecrets = .{};

    if (entry.s3Key != null and entry.s3Key.?.len > 0 and std.mem.startsWith(u8, entry.path, "s3:")) {
        const vault = try getVault(getDefaultVaultType());
        const s3Secret = try vault.get(allocator, io, entry.s3Key.?);
        if (s3Secret) |secret| {
            result.s3Config = try parseS3Credentials(allocator, secret.value);
        }
    }

    if (entry.encryptionKey != null and entry.encryptionKey.?.len > 0) {
        result.encryptionKeyName = entry.encryptionKey;
    }

    if (entry.geocodingKey != null and entry.geocodingKey.?.len > 0) {
        result.geocodingKeyName = entry.geocodingKey;
    }

    return result;
}

//
// Common options interface that all commands should extend
//
pub const IBaseCommandOptions = struct {
    //
    // Database directory path.
    //
    db: ?[]const u8 = null,

    //
    // Name of the encryption key stored in the vault (e.g. "my-photos").
    //
    key: ?[]const u8 = null,

    //
    // Enables verbose logging.
    //
    verbose: ?bool = null,

    //
    // Enables tool output logging.
    //
    tools: ?bool = null,

    //
    // Non-interactive mode - use defaults and command line arguments.
    //
    yes: ?bool = null,

    //
    // Set the current working directory for directory selection prompts.
    //
    cwd: ?[]const u8 = null,

    //
    // Session identifier for write lock tracking.
    //
    sessionId: ?[]const u8 = null,

    //
    // Number of worker threads to use for parallel processing.
    // Defaults to the number of CPU cores.
    // Supported by commands that use the task queue (e.g., verify, check).
    // (Declared as a number in TypeScript, but commander passes the command line text.)
    //
    workers: ?[]const u8 = null,

    //
    // Task timeout in milliseconds.
    // Supported by commands that use the task queue (e.g., verify).
    // Defaults to 40 minutes (2400000ms).
    // (Declared as a number in TypeScript, but commander passes the command line text.)
    //
    timeout: ?[]const u8 = null,
};

// Not ported: ICreateCommandOptions (only used by commands that create databases).

//
// Common dependencies injected into CLI commands.
//
pub const ICommandContext = struct {
    // Generates unique identifiers.
    uuidGenerator: IUuidGenerator,

    // Provides the current time.
    timestampProvider: ITimestampProvider,

    // Identifies the command session.
    sessionId: []const u8,

    // The temporary directory of the command session.
    sessionTempDir: []const u8,

    // The worker pool that runs background tasks.
    workerPool: IQueueBackend,
};

//
// Equivalent of JavaScript `Number(text)` for the numeric options (NaN when the text is not a number).
//
pub fn jsNumber(textValue: []const u8) f64 {
    const trimmed = std.mem.trim(u8, textValue, " \t\r\n");
    if (trimmed.len == 0) {
        return 0;
    }
    return std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
}

//
// The state of the termination callback registered by initContext.
//
const ICleanupContext = struct {
    // The worker pool to shut down.
    workerPool: *WorkerPoolBun,

    // The session temporary directory to delete on success.
    sessionTempDir: []const u8,
};

//
// Termination callback: shuts down the worker pool, then deletes the session temporary directory on
// success or reports that it was retained on failure.
//
fn cleanupOnTermination(context: ?*anyopaque, io: std.Io, exitCode: u8) anyerror!void {
    const cleanup: *ICleanupContext = @ptrCast(@alignCast(context.?));
    cleanup.workerPool.shutdown();
    var buffer: [4096]u8 = undefined;
    if (exitCode == 0) {
        // Successful exit - clean up temp directory
        std.Io.Dir.cwd().deleteTree(io, cleanup.sessionTempDir) catch |err| {
            log.exception(std.fmt.bufPrint(&buffer, "Failed to clean up temporary directory {s}", .{cleanup.sessionTempDir}) catch "Failed to clean up temporary directory", err);
            return;
        };
        log.verbose(std.fmt.bufPrint(&buffer, "Cleaned up temporary directory \"{s}\"", .{cleanup.sessionTempDir}) catch "Cleaned up temporary directory");
    }
    else {
        // Error exit - retain temp directory for inspection
        log.info(std.fmt.bufPrint(&buffer, "Temporary files retained for inspection: {s}", .{cleanup.sessionTempDir}) catch "Temporary files retained for inspection");
    }
}

//
// Wraps a command function to inject common dependencies.
// TypeScript returns a wrapper that does this before calling the command; in Zig the caller (index.zig)
// calls initContext with the parsed options and then calls the command with the returned context.
// Everything is allocated with the allocator, which must live until the process exits.
//
pub fn initContext(allocator: std.mem.Allocator, io: std.Io, options: IBaseCommandOptions) !ICommandContext {
    // Configure logging
    try configureLog(allocator, io, .{
        .verbose = options.verbose,
        .tools = options.tools,
    });

    // Test providers are automatically configured when NODE_ENV === "testing"
    const isTesting = std.mem.eql(u8, node_utils.process_env.getEnv("NODE_ENV") orelse "", "testing");
    var uuidGenerator: IUuidGenerator = undefined;
    if (isTesting) {
        const generator = try allocator.create(TestUuidGenerator);
        generator.* = try TestUuidGenerator.init(allocator);
        uuidGenerator = generator.uuidGenerator();
    }
    else {
        const generator = try allocator.create(RandomUuidGenerator);
        generator.* = .{};
        uuidGenerator = generator.uuidGenerator();
    }
    var timestampProvider: ITimestampProvider = undefined;
    if (isTesting) {
        const provider = try allocator.create(TestTimestampProvider);
        provider.* = .{};
        timestampProvider = provider.timestampProvider();
    }
    else {
        const provider = try allocator.create(TimestampProvider);
        provider.* = .{};
        timestampProvider = provider.timestampProvider();
    }
    const sessionId = if (options.sessionId != null and options.sessionId.?.len > 0) options.sessionId.? else try uuidGenerator.generate(allocator, io);

    // Create a session temporary directory for this command execution
    const sessionTempDir = try std.fs.path.join(allocator, &.{ try getProcessTmpDir(allocator, io), "photosphere", sessionId });
    try std.Io.Dir.cwd().createDirPath(io, sessionTempDir);
    log.verbose(try std.fmt.allocPrint(allocator, "Created temporary directory for command session: \"{s}\"", .{sessionTempDir}));

    // Worker pool defaults to number of CPUs if not specified
    const workers: f64 = if (options.workers) |workersText| jsNumber(workersText) else @floatFromInt(std.Thread.getCpuCount() catch 1);
    const timeout: f64 = if (options.timeout) |timeoutText| jsNumber(timeoutText) else 2400000;
    const workerPool = try WorkerPoolBun.init(io, workers, timeout, .{
        .verbose = options.verbose,
        .tools = options.tools,
        .sessionId = sessionId,
    });
    setQueueBackend(workerPool.queueBackend());

    const context: ICommandContext = .{
        .uuidGenerator = uuidGenerator,
        .timestampProvider = timestampProvider,
        .sessionId = sessionId,
        .sessionTempDir = sessionTempDir,
        .workerPool = workerPool.queueBackend(),
    };

    // Register cleanup handler for termination
    const cleanup = try allocator.create(ICleanupContext);
    cleanup.* = .{ .workerPool = workerPool, .sessionTempDir = sessionTempDir };
    try registerTerminationCallback(io, .{ .context = cleanup, .function = cleanupOnTermination });

    return context;
}

//
// Result of the initialization
//
pub const IInitResult = struct {
    //
    // The resolved database directory
    //
    databaseDir: []const u8,

    //
    // Individual database dependencies
    //
    assetStorage: IStorage,

    //
    // Raw (unencrypted) storage - reads bytes exactly as stored on disk, with no decryption applied.
    // Use this when you need to inspect the raw on-disk bytes (e.g. to read encryption headers).
    //
    rawAssetStorage: IStorage,

    // The BSON database of the media file database.
    bsonDatabase: *BsonDatabase,

    // The session identifier.
    sessionId: []const u8,

    // The metadata collection of the BSON database.
    metadataCollection: *IBsonCollection,

    //
    // Vault key name for the Google geocoding API key linked to this database entry.
    // Call resolveGeocodingApiKey() with this value to obtain the actual API key.
    //
    geocodingKeyName: ?[]const u8 = null,

    //
    // S3 credentials resolved from the database entry's linked shared secret.
    //
    s3Config: ?IS3Credentials = null,
};

//
// Formats the lines of a "Did you mean" list
// (TypeScript: `similarNames.map(similarName => `  • ${pc.cyan(similarName)}`).join('\n')`).
//
fn didYouMeanList(allocator: std.mem.Allocator, similarNames: []const []const u8) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    for (similarNames) |similarName| {
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "  \u{2022} {s}", .{try pc.cyan(allocator, similarName)}));
    }
    return std.mem.join(allocator, "\n", lines.items);
}

//
// Shared database loading function for CLI commands.
// (TypeScript default: allowOlderVersions = false; callers pass it.)
//
pub fn loadDatabase(
    allocator: std.mem.Allocator,
    io: std.Io,
    dbDirOption: ?[]const u8,
    options: *IBaseCommandOptions,
    uuidGenerator: IUuidGenerator,
    timestampProvider: ITimestampProvider,
    sessionId: []const u8,
    allowOlderVersions: bool,
) !IInitResult { //todo: Move into api.

    const nonInteractive = options.yes orelse false;

    // Ensure media processing tools are available
    try ensureMediaProcessingTools(allocator, io, nonInteractive);

    var dbDir: []const u8 = undefined;
    if (dbDirOption) |value| {
        dbDir = value;
    }
    else {
        const cwd = if (options.cwd != null and options.cwd.?.len > 0) options.cwd.? else try std.process.currentPathAlloc(io, allocator);
        dbDir = try getDirectoryForCommand(allocator, io, .existing, nonInteractive, cwd);
    }

    // Try to resolve the --db value to a database entry in databases.json.
    // This allows --db to accept a database name in addition to a path.
    var resolvedSecrets: ?IResolvedDatabaseSecrets = null;
    const matchedEntry = try resolveDatabaseEntry(allocator, io, dbDir);
    if (matchedEntry) |entry| {
        // If matched by name (dbDir doesn't equal the entry's path), use the entry's path.
        if (!std.mem.eql(u8, entry.path, dbDir)) {
            dbDir = entry.path;
        }
        resolvedSecrets = try resolveSecretsFromEntry(allocator, io, entry);
    }

    const metaPath = try pathJoin(allocator, &.{ dbDir, ".db" });

    if (std.mem.startsWith(u8, dbDir, "s3:") or std.mem.startsWith(u8, metaPath, "s3:")) {
        const hasS3Config = if (resolvedSecrets) |secrets| secrets.s3Config != null else false;
        if (!hasS3Config) {
            _ = try configureS3IfNeeded(allocator, io, nonInteractive);
        }
    }

    var keyName = options.key;
    var keyPems: []const IEncryptionKeyPem = &.{};

    if (keyName != null and keyName.?.len > 0) {
        // Explicit --key overrides any resolved keys.
        keyPems = try resolveKeyPemsWithPrompt(allocator, io, keyName, nonInteractive, false);
        if (keyPems.len == 0) {
            try outro(io, try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} Encryption key \"{s}\" not found.\n  Use \"psi secrets list\" to see available keys.", .{keyName.?})), .{});
            exit(io, 1);
        }
    }

    var storageOptions = (try loadEncryptionKeysFromPem(allocator, keyPems)).options;

    const resolvedS3Config: ?IS3Credentials = if (resolvedSecrets) |secrets| secrets.s3Config else null;
    const s3Config = resolvedS3Config orelse (if (std.mem.startsWith(u8, dbDir, "s3:")) try getDefaultS3Config(allocator, io) else null);
    const created = try createStorage(allocator, io, dbDir, s3Config, storageOptions);
    var assetStorage = created.storage;
    const rawAssetStorage = created.rawStorage;

    //
    // Check that the files tree exists (.db/files.dat or legacy .db/tree.dat).
    //
    const hasFilesDat = try assetStorage.fileExists(allocator, io, ".db/files.dat");
    const hasTreeDat = try assetStorage.fileExists(allocator, io, ".db/tree.dat");
    if (!hasFilesDat and !hasTreeDat) {
        var notFoundMessage = try std.mem.concat(allocator, u8, &.{
            try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} No database found at: {s}\n  The database directory must contain a \".db\" folder with files.dat or tree.dat.", .{try pc.cyan(allocator, dbDir)})),
            try std.fmt.allocPrint(allocator, "\n\nTo create a new database at this directory, use:\n  {s}", .{try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "psi init --db {s}", .{dbDir}))}),
        });

        if (matchedEntry == null) {
            const similarNames = try findSimilarDatabaseNames(allocator, io, dbDir);
            if (similarNames.len > 0) {
                notFoundMessage = try std.fmt.allocPrint(allocator, "{s}\n\nDid you mean:\n{s}", .{ notFoundMessage, try didYouMeanList(allocator, similarNames) });
            }
        }

        try outro(io, notFoundMessage, .{});
        exit(io, 1);
    }

    if (!allowOlderVersions) {
        //
        // When trying to load the database and we don't allow older versions,
        // quickly load the version from the database and reject if the database is old.
        //
        const treePath = if (hasFilesDat) ".db/files.dat" else ".db/tree.dat";
        const databaseVersion = loadTreeVersion(allocator, io, treePath, assetStorage);
        if (databaseVersion != null and databaseVersion.? != 0 and databaseVersion.? < CURRENT_DATABASE_VERSION) {
            try outro(io, try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} Database version {d} is outdated. Current version is {d}. Please run 'psi upgrade' to upgrade your database.", .{ databaseVersion.?, CURRENT_DATABASE_VERSION })), .{});
            exit(io, 1);
        }
    }

    //
    // See if the database is encrypted and requires a key.
    //
    if (try assetStorage.fileExists(allocator, io, ".db/encryption.pub")) {
        if (keyPems.len == 0) {
            const encryptionKeyName: ?[]const u8 = if (resolvedSecrets) |secrets| secrets.encryptionKeyName else null;
            if (encryptionKeyName) |resolvedKeyName| {
                // Lazy fetch: the database is confirmed encrypted, so retrieve the key from vault now.
                keyPems = try resolveKeyPems(allocator, io, resolvedKeyName);
                if (keyPems.len == 0) {
                    try outro(io, try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} Encryption key \"{s}\" not found.\n  Use \"psi secrets list\" to see available keys.", .{resolvedKeyName})), .{});
                    const similarKeyNames = try findSimilarKeyNames(allocator, io, resolvedKeyName);
                    if (similarKeyNames.len > 0) {
                        log.info(try std.fmt.allocPrint(allocator, "Did you mean:\n{s}", .{try didYouMeanList(allocator, similarKeyNames)}));
                    }
                    exit(io, 1);
                }

                storageOptions = (try loadEncryptionKeysFromPem(allocator, keyPems)).options;

                assetStorage = (try createStorage(allocator, io, dbDir, s3Config, storageOptions)).storage;
            }
            else if (nonInteractive) {
                try outro(io, try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} This database is encrypted and requires a private key to access.\n  Please provide the key name using the --key option.\n\nExample:\n    {s}", .{try pc.cyan(allocator, "psi <command> --key my-photos")})), .{});
                exit(io, 1);
            }
            else {
                log.info(try pc.yellow(allocator, "This database is encrypted and requires a private key to access."));

                const selectedKeyName = try selectEncryptionKey(allocator, io, "Select the encryption key for this database:");
                keyName = selectedKeyName;
                options.key = keyName;

                keyPems = try resolveKeyPems(allocator, io, keyName);
                if (keyPems.len == 0) {
                    try outro(io, try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} Encryption key \"{s}\" not found.", .{keyName.?})), .{});
                    const similarKeyNames = try findSimilarKeyNames(allocator, io, keyName.?);
                    if (similarKeyNames.len > 0) {
                        log.info(try std.fmt.allocPrint(allocator, "Did you mean:\n{s}", .{try didYouMeanList(allocator, similarKeyNames)}));
                    }
                    exit(io, 1);
                }

                storageOptions = (try loadEncryptionKeysFromPem(allocator, keyPems)).options;

                assetStorage = (try createStorage(allocator, io, dbDir, s3Config, storageOptions)).storage;
            }
        }
    }

    // Create database instance (v6 layout: BSON under .db/bson)
    const database = try createMediaFileDatabase(allocator, assetStorage, uuidGenerator, timestampProvider);

    try loadSortIndexes(allocator, database.assetStorage, database.metadataCollection);

    return .{
        .databaseDir = dbDir,
        .assetStorage = assetStorage,
        .rawAssetStorage = rawAssetStorage,
        .bsonDatabase = database.bsonDatabase,
        .sessionId = sessionId,
        .metadataCollection = database.metadataCollection,
        .geocodingKeyName = if (resolvedSecrets) |secrets| secrets.geocodingKeyName else null,
        .s3Config = s3Config,
    };
}
// Not ported: createDatabase (only used by commands that create databases).
