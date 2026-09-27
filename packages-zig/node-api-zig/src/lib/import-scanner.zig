const std = @import("std");
const api = @import("api-zig");
const file_scanner = @import("file-scanner.zig");
const IFileCacheIdentity = api.import_assets_types.IFileCacheIdentity;
const FileScannedResult = file_scanner.FileScannedResult;
const IFileStat = file_scanner.IFileStat;
const ScanProgressCallback = file_scanner.ScanProgressCallback;

//
// One file a scanner is offering to the import.
//
// It is a scanned file plus, for a photo library item, what that file really is. The file itself is
// a temporary copy with a path and a modified time that were both minted by the copy, so it is the
// identity rather than the path that the hash is filed under. See IFileCacheIdentity.
// (Zig: the fields of FileScannedResult are written out, as Zig has no interface inheritance.)
//
pub const IScannedImportFile = struct {
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

    // What this file is identified as in the hash cache, or undefined when its own path identifies
    // it, which is the case for every file a manual import walks.
    cacheIdentity: ?IFileCacheIdentity,

    //
    // `{ ...result, cacheIdentity }`: a scanned file with the identity it is filed under.
    // (No TypeScript counterpart: TypeScript spreads the object.)
    //
    pub fn fromScanned(result: FileScannedResult, cacheIdentity: ?IFileCacheIdentity) IScannedImportFile {
        return .{
            .filePath = result.filePath,
            .fileStat = result.fileStat,
            .contentType = result.contentType,
            .labels = result.labels,
            .logicalPath = result.logicalPath,
            .cacheIdentity = cacheIdentity,
        };
    }
};

//
// The per-file callback a scanner pushes files at (TypeScript: `(result: IScannedImportFile) => Promise<void>`).
// (Zig: a closure; `function` is called with `context`. The file is only valid during the call.)
//
pub const VisitImportFile = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function.
    function: *const fn (context: ?*anyopaque, result: IScannedImportFile) anyerror!void,

    //
    // Invokes the callback.
    //
    pub fn call(self: VisitImportFile, result: IScannedImportFile) anyerror!void {
        return self.function(self.context, result);
    }
};

//
// Where the files an import takes in come from.
//
// The import orchestrator does not know whether it is importing a folder the user picked or a photo
// library it is watching. It asks a scanner to push files at it and takes what it is given, which is
// what lets one long-lived `import-assets` task serve both.
//
// This is deliberately the same call the orchestrator already made to `scanPaths`: a per-file
// callback that is awaited, and a progress callback. Nothing was invented for it, so the change in
// the orchestrator is the one line that used to call `scanPaths` directly.
//
// There is no "nothing right now" and no "exhausted". A paced scanner simply does not call back
// until its budget allows, and a finite one returns when its walk is done.
//
pub const IImportScanner = struct {
    // Pointer to the implementation.
    ptr: *anyopaque,

    // The implementation's functions.
    vtable: *const VTable,

    //
    // The functions an implementation of IImportScanner provides.
    //
    pub const VTable = struct {
        // Pushes every file this scanner has, one at a time, and returns when there are no more.
        scan: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, visitFile: VisitImportFile, onProgress: ScanProgressCallback) anyerror!void,

        // Releases whatever the scanner materialised for one file, once the import has finished with it.
        release: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!void,
    };

    //
    // Pushes every file this scanner has, one at a time, and returns when there are no more.
    //
    // A scanner that watches somewhere for new files does not return until the import is cancelled,
    // which is the one genuine difference between the two kinds.
    //
    pub fn scan(self: IImportScanner, allocator: std.mem.Allocator, io: std.Io, visitFile: VisitImportFile, onProgress: ScanProgressCallback) anyerror!void {
        return self.vtable.scan(self.ptr, allocator, io, visitFile, onProgress);
    }

    //
    // Releases whatever the scanner materialised for one file, once the import has finished with it.
    //
    // A folder's files are already files and there is nothing to release. A photo library item is
    // not a file at all: it had to be copied into the app's sandbox to be read, and that copy is
    // deleted here. Called for every file the scanner pushed, whatever the import made of it.
    //
    pub fn release(self: IImportScanner, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!void {
        return self.vtable.release(self.ptr, allocator, io, filePath);
    }
};
