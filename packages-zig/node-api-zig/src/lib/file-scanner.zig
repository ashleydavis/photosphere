const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const storage_zig = @import("storage-zig");
const mime_module = @import("third-party/mime/index.zig");
const jszip = @import("third-party/jszip/index.zig");
const errors = utils.errors;
const log = &utils.log.log;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const path = node_utils.path;
const pathExists = node_utils.fs.pathExists;
const localeCompareNumeric = storage_zig.locale_compare.localeCompareNumeric;
const JSZip = jszip.JSZip;

//
// File statistics interface
//
pub const IFileStat = struct {
    // The content type of the file (optional).
    contentType: ?[]const u8 = null,

    // The length of the file in bytes.
    length: u64,

    // The last modified date of the file (milliseconds since the Unix epoch, like a JS Date).
    lastModified: i64,
};

//
// Scanner state that is passed through scanning operations
//
pub const ScannerState = struct {
    // The name of what is being scanned right now, for the progress callback.
    currentlyScanning: ?[]const u8,

    // How many files were ignored (not media, or not readable).
    numFilesIgnored: u64,

    // How many files failed (a zip that could not be read, an entry that extracted empty).
    numFilesFailed: u64,

    // Temporary directory for extracted files from this scanning session
    tempDir: []const u8,
};

//
// Progress callback for scanning operations.
// (A Zig closure: `function` is called with `context`; the state is only valid during the call.)
//
pub const ScanProgressCallback = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function.
    function: *const fn (context: ?*anyopaque, currentlyScanning: ?[]const u8, state: *const ScannerState) void,

    //
    // Invokes the callback.
    //
    pub fn call(self: ScanProgressCallback, currentlyScanning: ?[]const u8, state: *const ScannerState) void {
        self.function(self.context, currentlyScanning, state);
    }
};

//
// Result of scanning a single file
//
pub const FileScannedResult = struct {
    // Actual file path (temporary file path if extracted from zip, otherwise the original file path)
    filePath: []const u8,

    // The size and modified time of the file.
    fileStat: IFileStat,

    // The MIME type of the file.
    contentType: []const u8,

    // Labels to attach to the asset.
    labels: []const []const u8,

    // Logical path showing root zip file, parent zip names, and file name (always set - equals filePath for non-zip files)
    logicalPath: []const u8,
};

//
// Simple callback for visiting each file found during scanning
// (A Zig closure: `function` is called with `context`.)
//
pub const SimpleFileCallback = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function.
    function: *const fn (context: ?*anyopaque, result: FileScannedResult) anyerror!void,

    //
    // Invokes the callback.
    //
    pub fn call(self: SimpleFileCallback, result: FileScannedResult) anyerror!void {
        return self.function(self.context, result);
    }
};

//
// Scanner configuration options
//
pub const ScannerOptions = struct {
    //
    // Patterns to ignore during scanning (default: [/\.db/])
    // (Zig: every pattern Photosphere passes is a regular expression of literal text, which matches a name that
    // contains that text anywhere, so a pattern is written as the text itself.)
    //
    ignorePatterns: ?[]const []const u8 = null,
};

//
// Interface for ordered file results from directory walking
//
const IOrderedFile = struct {
    // The path of the file.
    fileName: []const u8,
};

//
// Determines if a file should be included based on its content type
//
fn shouldIncludeFile(contentType: []const u8) bool {
    if (std.mem.eql(u8, contentType, "video/mp2t")) {
        // TypeScript files get detected as video/mp2t, but we don't want to include them.
        // So we don't support .ts video files. If someone wants to add support for .ts files, they can change this later.
        return false;
    }

    if (std.mem.eql(u8, contentType, "image/vnd.fastbidsheet")) {
        // .fbs files are not supported.
        return false;
    }

    if (std.mem.eql(u8, contentType, "image/svg+xml")) {
        // SVG files are not supported yet, so we ignore them.
        return false;
    }

    if (std.mem.eql(u8, contentType, "application/zip")) {
        return true;
    }

    if (std.mem.startsWith(u8, contentType, "image/vnd.adobe.photoshop")) {
        // Don't yet know how to validate or process PSD files. This might come later.
        return false;
    }

    if (std.mem.startsWith(u8, contentType, "image")) {
        return true;
    }

    if (std.mem.startsWith(u8, contentType, "video")) {
        return true;
    }

    return false;
}

//
// Gets the MIME type of a path (TypeScript: `mime.getType(path)`).
// (No TypeScript counterpart: mime is imported as a default export.)
//
fn getMimeType(allocator: std.mem.Allocator, filePath: []const u8) !?[]const u8 {
    const mime = try mime_module.mime();
    return mime.getType(allocator, filePath);
}

//
// A directory entry that walkDirectory sorts (TypeScript: the Dirent it filters and sorts).
//
const IDirectoryEntry = struct {
    // The name of the entry.
    name: []const u8,
};

//
// Sort predicate for directory entries: `a.name.localeCompare(b.name, undefined, { numeric: true })`.
//
fn entryLessThan(context: void, left: IDirectoryEntry, right: IDirectoryEntry) bool {
    _ = context;
    return localeCompareNumeric(left.name, right.name) < 0;
}

//
// Visits each file found by walkDirectory (TypeScript: the body of the `for await` loop over the generator).
//
const OrderedFileVisitor = struct {
    // The state of the visitor, passed to function.
    context: *anyopaque,

    // The visitor function.
    function: *const fn (context: *anyopaque, orderedFile: IOrderedFile) anyerror!void,
};

//
// Walks a directory recursively and yields files in alphanumeric order
// (Zig: each file is handed to the visitor, in the order the TypeScript generator yields them.)
//
fn walkDirectory(allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8, ignorePatterns: []const []const u8, visitor: OrderedFileVisitor) anyerror!void {
    if (!pathExists(io, dirPath)) {
        return;
    }

    // Phase 1: List and yield all files in the current directory
    var files: std.ArrayList(IDirectoryEntry) = .empty;
    var dirs: std.ArrayList(IDirectoryEntry) = .empty;
    {
        var directory = try std.Io.Dir.cwd().openDir(io, dirPath, .{ .iterate = true });
        defer directory.close(io);
        var entries = directory.iterate();
        while (try entries.next(io)) |entry| {
            if (isIgnored(entry.name, ignorePatterns)) {
                continue;
            }
            if (entry.kind == .file) {
                try files.append(allocator, .{ .name = try allocator.dupe(u8, entry.name) });
            }
            else if (entry.kind == .directory) {
                try dirs.append(allocator, .{ .name = try allocator.dupe(u8, entry.name) });
            }
        }
    }

    // Alphanumeric sort to simulate the order of file listing from S3
    std.mem.sort(IDirectoryEntry, files.items, {}, entryLessThan);

    for (files.items) |file| {
        const fileName = try path.join(allocator, &.{ dirPath, file.name });
        try visitor.function(visitor.context, .{ .fileName = fileName });
    }

    // Phase 2: List all subdirectories and recursively walk each one
    // Alphanumeric sort for consistent ordering
    std.mem.sort(IDirectoryEntry, dirs.items, {}, entryLessThan);

    for (dirs.items) |dir| {
        const subDirPath = try path.join(allocator, &.{ dirPath, dir.name });
        try walkDirectory(allocator, io, subDirPath, ignorePatterns, visitor);
    }
}

//
// Whether a name matches one of the ignore patterns (TypeScript: the isIgnored arrow function in walkDirectory).
//
fn isIgnored(name: []const u8, ignorePatterns: []const []const u8) bool {
    for (ignorePatterns) |pattern| {
        if (std.mem.indexOf(u8, name, pattern) != null) {
            return true;
        }
    }
    return false;
}

//
// The patterns walkDirectory ignores when it is given none (TypeScript: its default parameter value).
//
const DEFAULT_WALK_IGNORE_PATTERNS = [_][]const u8{
    "node_modules",
    ".git",
    ".DS_Store",
};

//
// Formats the full zip path for log messages, showing all parents in the stack
//
fn formatZipDisplayPath(allocator: std.mem.Allocator, zipPathStack: []const []const u8) ![]const u8 {
    return std.mem.join(allocator, " / ", zipPathStack);
}

//
// Constructs a logical path showing root zip file, parent zip names, and file name
// zipPathStack should include the root zip file path as the first element, followed by nested zip names
//
pub fn constructLogicalPath(allocator: std.mem.Allocator, zipPathStack: []const []const u8, fileName: []const u8) ![]const u8 {
    const logicalPathParts = try allocator.alloc([]const u8, zipPathStack.len + 1);
    @memcpy(logicalPathParts[0..zipPathStack.len], zipPathStack);
    logicalPathParts[zipPathStack.len] = fileName;
    return std.mem.join(allocator, "/", logicalPathParts);
}

//
// Formats a truncated zip path for progress callbacks, showing only root and last nested zip
//
fn formatZipProgressPath(allocator: std.mem.Allocator, zipPathStack: []const []const u8) ![]const u8 {
    if (zipPathStack.len == 0) {
        return errors.throwError("zipPathStack cannot be empty", .{});
    }

    const rootZipName = path.basename(zipPathStack[0]);
    const truncatedRoot = try truncateUtf16(allocator, rootZipName, 50);

    if (zipPathStack.len == 1) {
        // Just the root zip
        return truncatedRoot;
    }
    else if (zipPathStack.len == 2) {
        // Root + 1 nested zip, no "..."
        const lastNestedZip = path.basename(zipPathStack[1]);
        return std.fmt.allocPrint(allocator, "{s} / {s}", .{ truncatedRoot, lastNestedZip });
    }
    else {
        // More than two entries (root + at least 2 nested), show "..."
        const lastNestedZip = path.basename(zipPathStack[zipPathStack.len - 1]);
        return std.fmt.allocPrint(allocator, "{s} / ... / {s}", .{ truncatedRoot, lastNestedZip });
    }
}

//
// JavaScript's `text.length > maximum ? text.substring(0, maximum) : text`, where the length counts UTF-16 code
// units. A cut that splits a character outside the Basic Multilingual Plane keeps its high surrogate, which is
// written out as U+FFFD, so that is what the cut part ends with. (No TypeScript counterpart.)
//
fn truncateUtf16(allocator: std.mem.Allocator, text: []const u8, maximum: usize) ![]const u8 {
    var units: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const sequenceLength = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const characterUnits: usize = if (sequenceLength == 4) 2 else 1;
        if (units + characterUnits > maximum) {
            if (units < maximum) {
                return std.fmt.allocPrint(allocator, "{s}\u{FFFD}", .{text[0..index]});
            }
            return text[0..index];
        }
        units += characterUnits;
        index += @min(sequenceLength, text.len - index);
    }
    return text;
}

//
// Node's `fs.stat` for a path: the kind, size and modified time of what the path leads to (following links), or
// the error Node reports. (No TypeScript counterpart: TypeScript calls fs.stat.)
//
fn statPath(io: std.Io, filePath: []const u8) !std.Io.File.Stat {
    return std.Io.Dir.cwd().statFile(io, filePath, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return errors.throwError("ENOENT: no such file or directory, stat '{s}'", .{filePath});
        }
        return err;
    };
}

//
// The modified time of a stat, as a JavaScript Date holds it (whole milliseconds, truncated towards zero as the
// Date constructor truncates mtimeMs, so a time before 1970 rounds up).
// (No TypeScript counterpart: TypeScript reads `stats.mtime`.)
//
fn statModifiedTime(stat: std.Io.File.Stat) i64 {
    return stat.mtime.toMilliseconds();
}

//
// Scans files from a zip file
// zipFilePath is always a valid zip file on disk (either root or extracted temp file)
// zipPathStack is an array representing the zip hierarchy, with the root zip path as the first element
//
fn scanZipFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    zipFilePath: []const u8,
    fileStat: IFileStat,
    zipPathStack: []const []const u8,
    visitFile: SimpleFileCallback,
    progressCallback: ?ScanProgressCallback,
    state: *ScannerState,
    options: ScannerOptions,
    tempDir: []const u8,
    uuidGenerator: IUuidGenerator,
) anyerror!void {
    _ = fileStat;
    const displayPath = try formatZipDisplayPath(allocator, zipPathStack);
    log.verbose(try std.fmt.allocPrint(allocator, "Scanning zip file \"{s}\" for media files.", .{displayPath}));

    if (progressCallback) |callback| {
        const progressPath = try formatZipProgressPath(allocator, zipPathStack);
        state.currentlyScanning = progressPath;
        callback.call(state.currentlyScanning, state);
    }

    var zip = JSZip.init(allocator);
    const zipBuffer = std.Io.Dir.cwd().readFileAlloc(io, zipFilePath, allocator, .unlimited) catch |err| {
        log.exception(try std.fmt.allocPrint(allocator, "Failed to read zip file {s}", .{displayPath}), err);
        state.numFilesFailed += 1;
        return;
    };

    const unpacked = zip.loadAsync(zipBuffer) catch |err| {
        log.exception(try std.fmt.allocPrint(allocator, "Failed to load zip file {s}", .{displayPath}), err);
        state.numFilesFailed += 1;
        return;
    };

    for (unpacked.files.names.items) |fileName| {
        const zipObject = unpacked.files.get(fileName).?;
        if (!zipObject.dir) {
            const contentType = try getMimeType(allocator, fileName) orelse {
                log.verbose(try std.fmt.allocPrint(allocator, "Ignoring file {s} in zip {s} with unknown content type.", .{ fileName, displayPath }));
                state.numFilesIgnored += 1;
                continue;
            };

            if (!shouldIncludeFile(contentType)) {
                log.verbose(try std.fmt.allocPrint(allocator, "Ignoring file {s} in zip {s} with content type \"{s}\".", .{ fileName, displayPath, contentType }));
                state.numFilesIgnored += 1;
                continue;
            }

            const zipFileInfo: IFileStat = .{
                .contentType = contentType,
                .length = 0, // We can't reliably get the uncompressed size from JSZip.
                // TypeScript: `zipObject.date || fileStat.lastModified`; a Date is always truthy, so fileStat is never read.
                .lastModified = zipObject.date,
            };

            if (std.mem.eql(u8, contentType, "application/zip")) {
                // If it's a zip file, extract it to a temporary file, scan it, then delete it
                // Build the path stack for nested zips - add this zip name to the existing stack
                const nestedZipPathStack = try std.mem.concat(allocator, []const u8, &.{ zipPathStack, &.{fileName} });

                // Extract nested zip from this zip file to temp file
                var tempZipPath: ?[]const u8 = null;
                extractNestedZip(allocator, io, zipObject, fileName, displayPath, zipFileInfo, nestedZipPathStack, visitFile, progressCallback, state, options, tempDir, uuidGenerator, &tempZipPath) catch |err| {
                    // Keep file for inspection on error
                    if (tempZipPath) |keptPath| {
                        log.verbose(try std.fmt.allocPrint(allocator, "Keeping temporary zip file \"{s}\" for inspection due to error", .{keptPath}));
                    }
                    return err;
                };
            }
            else {
                // Extract file from zip to temporary file
                var tempFilePath: ?[]const u8 = null;
                extractFile(allocator, io, zipObject, fileName, displayPath, contentType, zipPathStack, visitFile, state, tempDir, uuidGenerator, &tempFilePath) catch |err| {
                    // Keep file for inspection on error
                    if (tempFilePath) |keptPath| {
                        log.verbose(try std.fmt.allocPrint(allocator, "Keeping temporary file \"{s}\" for inspection due to error", .{keptPath}));
                    }
                    return err;
                };
            }
        }
    }
}

//
// The body of scanZipFile's try block for a nested zip: extracts it to a temporary file and scans that.
// (No TypeScript counterpart: the try block is written inline; Zig needs it as a function to catch its errors.)
//
fn extractNestedZip(
    allocator: std.mem.Allocator,
    io: std.Io,
    zipObject: jszip.ZipObject,
    fileName: []const u8,
    displayPath: []const u8,
    zipFileInfo: IFileStat,
    nestedZipPathStack: []const []const u8,
    visitFile: SimpleFileCallback,
    progressCallback: ?ScanProgressCallback,
    state: *ScannerState,
    options: ScannerOptions,
    tempDir: []const u8,
    uuidGenerator: IUuidGenerator,
    tempZipPath: *?[]const u8,
) anyerror!void {
    const nestedZipBuffer = try zipObject.asyncNodeBuffer(allocator);
    tempZipPath.* = try path.join(allocator, &.{ tempDir, try std.fmt.allocPrint(allocator, "{s}.zip", .{try uuidGenerator.generate(allocator, io)}) });
    log.verbose(try std.fmt.allocPrint(allocator, "Extracting nested zip file \"{s}\" from {s} to temporary file \"{s}\"", .{ fileName, displayPath, tempZipPath.*.? }));
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = tempZipPath.*.?,
        .data = nestedZipBuffer,
    });

    // Verify the file was written correctly
    const zipStats = try statPath(io, tempZipPath.*.?);
    if (zipStats.size == 0) {
        log.@"error"(try std.fmt.allocPrint(allocator, "Extracted nested zip file \"{s}\" from {s} is empty (0 bytes), skipping", .{ fileName, displayPath }));
        state.numFilesFailed += 1;
        log.verbose(try std.fmt.allocPrint(allocator, "Keeping temporary zip file \"{s}\" for inspection due to error", .{tempZipPath.*.?}));
        return;
    }

    // Scan the extracted zip file
    try scanZipFile(
        allocator,
        io,
        tempZipPath.*.?,
        zipFileInfo,
        nestedZipPathStack, // Path stack including root zip and nested zips
        visitFile,
        progressCallback,
        state,
        options,
        tempDir,
        uuidGenerator,
    );
}

//
// The body of scanZipFile's try block for a media file: extracts it to a temporary file and visits it.
// (No TypeScript counterpart: the try block is written inline; Zig needs it as a function to catch its errors.)
//
fn extractFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    zipObject: jszip.ZipObject,
    fileName: []const u8,
    displayPath: []const u8,
    contentType: []const u8,
    zipPathStack: []const []const u8,
    visitFile: SimpleFileCallback,
    state: *ScannerState,
    tempDir: []const u8,
    uuidGenerator: IUuidGenerator,
    tempFilePath: *?[]const u8,
) anyerror!void {
    const fileBuffer = try zipObject.asyncNodeBuffer(allocator);
    const fileExt = path.extname(fileName);
    tempFilePath.* = try path.join(allocator, &.{ tempDir, try std.fmt.allocPrint(allocator, "{s}{s}", .{ try uuidGenerator.generate(allocator, io), fileExt }) });
    log.verbose(try std.fmt.allocPrint(allocator, "Extracting file \"{s}\" from zip {s} to temporary file \"{s}\"", .{ fileName, displayPath, tempFilePath.*.? }));
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = tempFilePath.*.?,
        .data = fileBuffer,
    });

    // Verify the file was written correctly
    const stats = try statPath(io, tempFilePath.*.?);
    if (stats.size == 0) {
        log.@"error"(try std.fmt.allocPrint(allocator, "Extracted file \"{s}\" from zip {s} is empty (0 bytes), skipping", .{ fileName, displayPath }));
        state.numFilesFailed += 1;
        log.verbose(try std.fmt.allocPrint(allocator, "Keeping temporary file \"{s}\" for inspection due to error", .{tempFilePath.*.?}));
        return;
    }

    // Create file stat from the actual extracted file
    const extractedFileInfo: IFileStat = .{
        .contentType = contentType,
        .length = stats.size,
        .lastModified = statModifiedTime(stats),
    };

    try visitFile.call(.{
        .filePath = tempFilePath.*.?, // Temporary file path
        .fileStat = extractedFileInfo,
        .contentType = contentType,
        .labels = &.{},
        .logicalPath = try constructLogicalPath(allocator, zipPathStack, fileName), // Logical path showing root zip, parent zips, and file name
    });
}

//
// What scanDirectory's loop over walkDirectory needs (TypeScript: the variables the loop body closes over).
//
const DirectoryScan = struct {
    // Allocates everything the scan keeps.
    allocator: std.mem.Allocator,

    // Io for the file system.
    io: std.Io,

    // Called for each media file.
    visitFile: SimpleFileCallback,

    // Reports progress.
    progressCallback: ?ScanProgressCallback,

    // The state of the scan.
    state: *ScannerState,

    // The scanner options.
    options: ScannerOptions,

    // Where zip entries are extracted to.
    tempDir: []const u8,

    // Names the extracted files.
    uuidGenerator: IUuidGenerator,

    //
    // The body of the `for await (const orderedFile of walkDirectory(...))` loop.
    //
    fn visitOrderedFile(context: *anyopaque, orderedFile: IOrderedFile) anyerror!void {
        const self: *DirectoryScan = @ptrCast(@alignCast(context));
        const allocator = self.allocator;
        const state = self.state;

        if (self.progressCallback) |callback| {
            state.currentlyScanning = path.basename(path.dirname(orderedFile.fileName));
            callback.call(state.currentlyScanning, state);
        }

        const contentType = try getMimeType(allocator, orderedFile.fileName);
        const filePath = orderedFile.fileName;
        const knownContentType = contentType orelse {
            log.verbose(try std.fmt.allocPrint(allocator, "Ignoring file \"{s}\" with unknown content type.", .{filePath}));
            state.numFilesIgnored += 1;
            return;
        };

        if (!shouldIncludeFile(knownContentType)) {
            log.verbose(try std.fmt.allocPrint(allocator, "Ignoring file \"{s}\" with specific content type \"{s}\".", .{ filePath, knownContentType }));
            state.numFilesIgnored += 1;
            return;
        }

        const stats = statPath(self.io, filePath) catch |err| {
            log.verbose(try std.fmt.allocPrint(allocator, "Could not get file info for \"{s}\", skipping: {s}", .{ filePath, errors.errorMessage(err) }));
            state.numFilesIgnored += 1;
            return;
        };

        if (stats.kind != .file) {
            log.verbose(try std.fmt.allocPrint(allocator, "\"{s}\" is not a file, skipping.", .{filePath}));
            state.numFilesIgnored += 1;
            return;
        }

        const fileInfo: IFileStat = .{
            .contentType = knownContentType,
            .length = stats.size,
            .lastModified = statModifiedTime(stats),
        };

        if (std.mem.eql(u8, knownContentType, "application/zip")) {
            // If it's a zip file, we need to scan its contents.
            // Start the zip path stack with the root zip file path
            try scanZipFile(allocator, self.io, filePath, fileInfo, &.{filePath}, self.visitFile, self.progressCallback, state, self.options, self.tempDir, self.uuidGenerator);
        }
        else {
            // Otherwise, process the file directly.
            try self.visitFile.call(.{
                .filePath = filePath,
                .fileStat = fileInfo,
                .contentType = knownContentType,
                .labels = &.{},
                .logicalPath = filePath, // For non-zip files, logicalPath equals filePath
            });
        }
    }
};

//
// Scans a directory for files
//
fn scanDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    directoryPath: []const u8,
    visitFile: SimpleFileCallback,
    progressCallback: ?ScanProgressCallback,
    state: *ScannerState,
    options: ScannerOptions,
    tempDir: []const u8,
    uuidGenerator: IUuidGenerator,
) anyerror!void {
    log.verbose(try std.fmt.allocPrint(allocator, "Scanning directory \"{s}\" for media files.", .{directoryPath}));

    if (progressCallback) |callback| {
        state.currentlyScanning = path.basename(directoryPath);
        callback.call(state.currentlyScanning, state);
    }

    var directoryScan: DirectoryScan = .{
        .allocator = allocator,
        .io = io,
        .visitFile = visitFile,
        .progressCallback = progressCallback,
        .state = state,
        .options = options,
        .tempDir = tempDir,
        .uuidGenerator = uuidGenerator,
    };
    try walkDirectory(allocator, io, directoryPath, options.ignorePatterns orelse &DEFAULT_WALK_IGNORE_PATTERNS, .{
        .context = &directoryScan,
        .function = DirectoryScan.visitOrderedFile,
    });

    log.verbose(try std.fmt.allocPrint(allocator, "Finished scanning directory \"{s}\" for media files.", .{directoryPath}));
}

//
// Scans a single file or directory (internal)
//
fn scanPathInternal(
    allocator: std.mem.Allocator,
    io: std.Io,
    unresolvedFilePath: []const u8,
    visitFile: SimpleFileCallback,
    progressCallback: ?ScanProgressCallback,
    state: *ScannerState,
    options: ScannerOptions,
    tempDir: []const u8,
    uuidGenerator: IUuidGenerator,
) anyerror!void {
    // Resolve to absolute path so workers (which may have different cwd) can access the file
    const currentPath = try std.process.currentPathAlloc(io, allocator);
    const filePath = try std.fs.path.resolve(allocator, &.{ currentPath, unresolvedFilePath });

    const stats = statPath(io, filePath) catch |err| {
        log.verbose(try std.fmt.allocPrint(allocator, "Path \"{s}\" does not exist: {s}", .{ filePath, errors.errorMessage(err) }));
        return;
    };

    if (stats.kind == .file) {
        // It's a file
        const contentType = try getMimeType(allocator, filePath) orelse {
            log.verbose(try std.fmt.allocPrint(allocator, "Ignoring file \"{s}\" with unknown content type.", .{filePath}));
            state.numFilesIgnored += 1;
            return;
        };

        if (!shouldIncludeFile(contentType)) {
            log.verbose(try std.fmt.allocPrint(allocator, "Ignoring file \"{s}\" with specific content type \"{s}\".", .{ filePath, contentType }));
            state.numFilesIgnored += 1;
            return;
        }

        const fileInfo: IFileStat = .{
            .contentType = contentType,
            .length = stats.size,
            .lastModified = statModifiedTime(stats),
        };

        if (std.mem.eql(u8, contentType, "application/zip")) {
            // If it's a zip file, we need to scan its contents.
            // Start the zip path stack with the root zip file path
            try scanZipFile(
                allocator,
                io,
                filePath,
                fileInfo,
                &.{filePath}, // Zip path stack starting with root zip path
                visitFile,
                progressCallback,
                state,
                options,
                tempDir,
                uuidGenerator,
            );
        }
        else {
            // Otherwise, process the file directly.
            try visitFile.call(.{
                .filePath = filePath,
                .fileStat = fileInfo,
                .contentType = contentType,
                .labels = &.{},
                .logicalPath = filePath, // For non-zip files, logicalPath equals filePath
            });
        }
    }
    else if (stats.kind == .directory) {
        try scanDirectory(allocator, io, filePath, visitFile, progressCallback, state, options, tempDir, uuidGenerator);
    }
}

//
// Scans a list of files or directories
//
pub fn scanPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
    visitFile: SimpleFileCallback,
    progressCallback: ?ScanProgressCallback,
    options: ScannerOptions,
    sessionTempDir: []const u8,
    uuidGenerator: IUuidGenerator,
) !void {
    // Create a file-scanner subdirectory under the session temp directory
    const tempDir = try path.join(allocator, &.{ sessionTempDir, "file-scanner" });
    try std.Io.Dir.cwd().createDirPath(io, tempDir);
    log.verbose(try std.fmt.allocPrint(allocator, "Created temporary directory for file scanning: \"{s}\"", .{tempDir}));

    var state: ScannerState = .{
        .currentlyScanning = null,
        .numFilesIgnored = 0,
        .numFilesFailed = 0,
        .tempDir = tempDir,
    };

    for (paths) |scanPathValue| {
        try scanPathInternal(allocator, io, scanPathValue, visitFile, progressCallback, &state, options, tempDir, uuidGenerator);
    }
}

//
// Convenience function to scan a single path
//
pub fn scanPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    filePath: []const u8,
    visitFile: SimpleFileCallback,
    progressCallback: ?ScanProgressCallback,
    options: ScannerOptions,
    sessionTempDir: []const u8,
    uuidGenerator: IUuidGenerator,
) !void {
    // Create a file-scanner subdirectory under the session temp directory
    const tempDir = try path.join(allocator, &.{ sessionTempDir, "file-scanner" });
    try std.Io.Dir.cwd().createDirPath(io, tempDir);
    log.verbose(try std.fmt.allocPrint(allocator, "Created temporary directory for file scanning: \"{s}\"", .{tempDir}));

    var state: ScannerState = .{
        .currentlyScanning = null,
        .numFilesIgnored = 0,
        .numFilesFailed = 0,
        .tempDir = tempDir,
    };

    try scanPathInternal(allocator, io, filePath, visitFile, progressCallback, &state, options, tempDir, uuidGenerator);
}
