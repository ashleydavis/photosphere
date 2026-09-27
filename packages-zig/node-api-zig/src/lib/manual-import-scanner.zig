const std = @import("std");
const utils = @import("utils-zig");
const file_scanner = @import("file-scanner.zig");
const import_scanner = @import("import-scanner.zig");
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ScannerOptions = file_scanner.ScannerOptions;
const ScanProgressCallback = file_scanner.ScanProgressCallback;
const FileScannedResult = file_scanner.FileScannedResult;
const scanPaths = file_scanner.scanPaths;
const IImportScanner = import_scanner.IImportScanner;
const IScannedImportFile = import_scanner.IScannedImportFile;
const VisitImportFile = import_scanner.VisitImportFile;

//
// The scanner for an import the user asked for: a fixed list of files and folders, walked once.
//
// This is exactly what `import-assets` did inline before there was a scanner at all, moved behind
// the interface and nothing else. It has to stay that way: manual import is the most used path in
// the application, and the CLI and Electron import smoke tests are what prove it did not change.
//
pub const ManualImportScanner = struct {
    //
    // The files and folders to walk.
    //
    paths: []const []const u8,

    //
    // What the scan ignores, and where it unpacks a zip to.
    //
    options: ScannerOptions,

    //
    // The directory a zip's contents are extracted into.
    //
    sessionTempDir: []const u8,

    //
    // Names the temporary files extracted from a zip.
    //
    uuidGenerator: IUuidGenerator,

    //
    // Creates the scanner.
    //
    pub fn init(paths: []const []const u8, options: ScannerOptions, sessionTempDir: []const u8, uuidGenerator: IUuidGenerator) ManualImportScanner {
        return .{
            .paths = paths,
            .options = options,
            .sessionTempDir = sessionTempDir,
            .uuidGenerator = uuidGenerator,
        };
    }

    //
    // Gets the IImportScanner interface for this scanner (the scanner must not move while it is used).
    //
    pub fn importScanner(self: *ManualImportScanner) IImportScanner {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The IImportScanner functions of this scanner.
    //
    const vtable: IImportScanner.VTable = .{
        .scan = scanErased,
        .release = releaseErased,
    };

    //
    // IImportScanner.scan for this implementation.
    //
    fn scanErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, visitFile: VisitImportFile, onProgress: ScanProgressCallback) anyerror!void {
        const self: *ManualImportScanner = @ptrCast(@alignCast(ptr));
        return self.scan(allocator, io, visitFile, onProgress);
    }

    //
    // IImportScanner.release for this implementation.
    //
    fn releaseErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!void {
        const self: *ManualImportScanner = @ptrCast(@alignCast(ptr));
        return self.release(allocator, io, filePath);
    }

    //
    // Hands each scanned file on without a cache identity (TypeScript: the
    // `result => visitFile({ ...result, cacheIdentity: undefined })` arrow function).
    //
    fn visitScannedFile(context: ?*anyopaque, result: FileScannedResult) anyerror!void {
        const visitFile: *const VisitImportFile = @ptrCast(@alignCast(context.?));
        try visitFile.call(IScannedImportFile.fromScanned(result, null));
    }

    //
    // Walks the paths once and returns, which is what ends the import.
    //
    pub fn scan(self: *ManualImportScanner, allocator: std.mem.Allocator, io: std.Io, visitFile: VisitImportFile, onProgress: ScanProgressCallback) !void {
        try scanPaths(
            allocator,
            io,
            self.paths,
            // No cache identity: a file the user picked is identified by its own path, exactly as it
            // always was. Only a photo library item needs anything else.
            .{
                .context = @constCast(&visitFile),
                .function = visitScannedFile,
            },
            onProgress,
            self.options,
            self.sessionTempDir,
            self.uuidGenerator,
        );
    }

    //
    // Nothing to release. These files were already files before the import looked at them, and a
    // file the user asked to import is not the import's to delete.
    //
    pub fn release(self: *ManualImportScanner, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
        _ = self;
        _ = allocator;
        _ = io;
        _ = filePath;
    }
};
