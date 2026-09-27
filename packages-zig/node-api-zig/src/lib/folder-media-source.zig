const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const api = @import("api-zig");
const bdb = @import("bdb-zig");
const file_scanner = @import("file-scanner.zig");
const media_source = @import("media-source.zig");
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const path = node_utils.path;
const localeCompare = bdb.locale_compare.localeCompare;
const IFolderAutoImportSource = api.auto_import_settings.IFolderAutoImportSource;
const scanPaths = file_scanner.scanPaths;
const FileScannedResult = file_scanner.FileScannedResult;
const IMediaItem = media_source.IMediaItem;
const IMediaSource = media_source.IMediaSource;
const IMediaSourceListPage = media_source.IMediaSourceListPage;
const MediaSourceDeleteError = media_source.MediaSourceDeleteError;

//
// A media source over folders on the local filesystem, used by the CLI and the desktop app.
//
// Enumeration goes through the existing `scanPaths`, so the content-type filtering and zip handling
// the manual import already does are reused rather than written a second time.
//

//
// An item found by a scan, together with where it really lives on disk. A file inside a zip has no
// disk path of its own, which is what stops the cleanup deleting it.
//
const IScannedItem = struct {
    // The item as the auto-import task sees it.
    item: IMediaItem,

    // The file on disk backing the item, or undefined when it came out of a zip archive.
    diskPath: ?[]const u8,
};

//
// Sort predicate for the scanned items: `left.item.sourceId.localeCompare(right.item.sourceId)`.
//
fn scannedItemLessThan(context: void, left: IScannedItem, right: IScannedItem) bool {
    _ = context;
    return localeCompare(left.item.sourceId, right.item.sourceId) < 0;
}

//
// What the callback FolderMediaSource.scan passes to scanPaths needs (TypeScript: the variables the
// `async result => { ... }` arrow function closes over).
//
const FolderScan = struct {
    // Allocates the scanned items.
    allocator: std.mem.Allocator,

    // The folder being walked.
    folder: IFolderAutoImportSource,

    // The folder being walked, resolved to an absolute path.
    folderPath: []const u8,

    // Everything found so far.
    scanned: *std.ArrayList(IScannedItem),

    //
    // The body of the arrow function: keeps each file the folder's recurse flag allows.
    //
    fn visit(context: ?*anyopaque, result: FileScannedResult) anyerror!void {
        const self: *FolderScan = @ptrCast(@alignCast(context.?));
        const allocator = self.allocator;

        // A non-recursive folder takes only the files sitting directly in it. The
        // scanner always walks the whole tree, so the filtering happens here.
        const isFromZip = !std.mem.eql(u8, result.logicalPath, result.filePath);
        if (!self.folder.recurse and !isFromZip and !std.mem.eql(u8, path.dirname(result.filePath), self.folderPath)) {
            return;
        }

        try self.scanned.append(allocator, .{
            .item = .{
                .sourceId = try allocator.dupe(u8, result.logicalPath),
                .filePath = try allocator.dupe(u8, result.filePath),
                .displayName = try allocator.dupe(u8, path.basename(result.logicalPath)),
                .contentType = try allocator.dupe(u8, result.contentType),
                .size = result.fileStat.length,
                .createdAt = result.fileStat.lastModified,
            },
            .diskPath = if (isFromZip) null else try allocator.dupe(u8, result.filePath),
        });
    }
};

//
// A media source over a list of watched folders.
//
pub const FolderMediaSource = struct {
    // Allocates everything the source keeps, for as long as it lives. (No TypeScript counterpart.)
    allocator: std.mem.Allocator,

    // The folders being watched, each with its own recurse flag.
    folders: []const IFolderAutoImportSource,

    // Temporary directory the scanner extracts zip members into.
    sessionTempDir: []const u8,

    // Generates the names of extracted temporary files.
    uuidGenerator: IUuidGenerator,

    // The most recent scan, kept so paging through a large library does not rescan for every page.
    // Dropped when the cursor is not in it.
    scannedItems: ?[]IScannedItem,

    // Where each scanned item really lives on disk, by source id. Populated by scanning and used by
    // deleteItems, so cleanup never guesses at a path.
    diskPathsBySourceId: std.StringHashMapUnmanaged([]const u8),

    //
    // Creates the source (TypeScript: the constructor).
    //
    pub fn init(allocator: std.mem.Allocator, folders: []const IFolderAutoImportSource, sessionTempDir: []const u8, uuidGenerator: IUuidGenerator) FolderMediaSource {
        return .{
            .allocator = allocator,
            .folders = folders,
            .sessionTempDir = sessionTempDir,
            .uuidGenerator = uuidGenerator,
            .scannedItems = null,
            .diskPathsBySourceId = .empty,
        };
    }

    //
    // Gets the IMediaSource interface for this source (the source must not move while it is used).
    //
    pub fn mediaSource(self: *FolderMediaSource) IMediaSource {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The IMediaSource functions of this source.
    //
    const vtable: IMediaSource.VTable = .{
        .listPage = listPageErased,
        .openItem = openItemErased,
        .closeItem = closeItemErased,
        .deleteItems = deleteItemsErased,
    };

    //
    // IMediaSource.listPage for this implementation.
    //
    fn listPageErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, cursor: ?[]const u8, pageSize: usize) anyerror!IMediaSourceListPage {
        const self: *FolderMediaSource = @ptrCast(@alignCast(ptr));
        return self.listPage(allocator, io, cursor, pageSize);
    }

    //
    // IMediaSource.openItem for this implementation.
    //
    fn openItemErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror![]const u8 {
        const self: *FolderMediaSource = @ptrCast(@alignCast(ptr));
        return self.openItem(allocator, io, item);
    }

    //
    // IMediaSource.closeItem for this implementation.
    //
    fn closeItemErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror!void {
        const self: *FolderMediaSource = @ptrCast(@alignCast(ptr));
        return self.closeItem(allocator, io, item);
    }

    //
    // IMediaSource.deleteItems for this implementation.
    //
    fn deleteItemsErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, sourceIds: []const []const u8) anyerror!void {
        const self: *FolderMediaSource = @ptrCast(@alignCast(ptr));
        return self.deleteItems(allocator, io, sourceIds);
    }

    //
    // Walks every watched folder and returns what is there now, in a stable order.
    //
    fn scan(self: *FolderMediaSource, io: std.Io) ![]IScannedItem {
        const allocator = self.allocator;
        var scanned: std.ArrayList(IScannedItem) = .empty;

        for (self.folders) |folder| {
            const currentPath = try std.process.currentPathAlloc(io, allocator);
            const folderPath = try std.fs.path.resolve(allocator, &.{ currentPath, folder.path });

            var folderScan: FolderScan = .{
                .allocator = allocator,
                .folder = folder,
                .folderPath = folderPath,
                .scanned = &scanned,
            };
            try scanPaths(
                allocator,
                io,
                &.{folderPath},
                .{
                    .context = &folderScan,
                    .function = FolderScan.visit,
                },
                null,
                .{
                    .ignorePatterns = &.{".db"},
                },
                self.sessionTempDir,
                self.uuidGenerator,
            );
        }

        // The listing order has to be the same every time, because the backfill cursor is a position
        // in it. The scanner's own order is stable within one folder but says nothing about how two
        // folders sort against each other.
        std.mem.sort(IScannedItem, scanned.items, {}, scannedItemLessThan);

        self.diskPathsBySourceId = .empty;
        for (scanned.items) |scannedItem| {
            if (scannedItem.diskPath) |diskPath| {
                try self.diskPathsBySourceId.put(allocator, scannedItem.item.sourceId, diskPath);
            }
        }

        return scanned.items;
    }

    //
    // Returns one page of the folders' contents, starting after the item named by the cursor.
    //
    pub fn listPage(self: *FolderMediaSource, allocator: std.mem.Allocator, io: std.Io, cursor: ?[]const u8, pageSize: usize) !IMediaSourceListPage {
        if (cursor == null or self.scannedItems == null) {
            self.scannedItems = try self.scan(io);
        }

        var startIndex: usize = 0;
        if (cursor) |cursorSourceId| {
            const cursorIndex = findSourceIdIndex(self.scannedItems.?, cursorSourceId);
            if (cursorIndex == null) {
                // The item the cursor named is gone, so the cached listing cannot be trusted to
                // position us. Rescan and resume at the first item that sorts after the cursor,
                // which keeps the backfill moving forwards rather than starting over.
                self.scannedItems = try self.scan(io);
                startIndex = self.scannedItems.?.len;
                for (self.scannedItems.?, 0..) |scannedItem, index| {
                    if (localeCompare(scannedItem.item.sourceId, cursorSourceId) > 0) {
                        startIndex = index;
                        break;
                    }
                }
            }
            else {
                startIndex = cursorIndex.? + 1;
            }
        }

        const scannedItems = self.scannedItems.?;
        const page = scannedItems[@min(startIndex, scannedItems.len)..@min(startIndex + pageSize, scannedItems.len)];
        const endIndex = startIndex + page.len;
        const items = try allocator.alloc(IMediaItem, page.len);
        for (page, 0..) |scannedItem, index| {
            items[index] = scannedItem.item;
        }
        return .{
            .items = items,
            .nextCursor = if (endIndex < scannedItems.len and page.len > 0)
                page[page.len - 1].item.sourceId
            else
                null,
        };
    }

    //
    // `scannedItems.findIndex(scannedItem => scannedItem.item.sourceId === cursor)`, or null for -1.
    // (No TypeScript counterpart.)
    //
    fn findSourceIdIndex(scannedItems: []const IScannedItem, sourceId: []const u8) ?usize {
        for (scannedItems, 0..) |scannedItem, index| {
            if (std.mem.eql(u8, scannedItem.item.sourceId, sourceId)) {
                return index;
            }
        }
        return null;
    }

    //
    // A folder item is already a file, so there is nothing to materialise.
    //
    pub fn openItem(self: *FolderMediaSource, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) ![]const u8 {
        _ = self;
        _ = allocator;
        _ = io;
        return item.filePath;
    }

    //
    // Nothing was materialised, so there is nothing to release.
    //
    pub fn closeItem(self: *FolderMediaSource, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) !void {
        _ = self;
        _ = allocator;
        _ = io;
        _ = item;
    }

    //
    // Deletes the named source files. An item that came out of a zip archive has no file of its own
    // to delete, and neither does one this source has never listed, so both are named in the error
    // rather than silently passed over.
    //
    pub fn deleteItems(self: *FolderMediaSource, allocator: std.mem.Allocator, io: std.Io, sourceIds: []const []const u8) !void {
        var undeletable: std.ArrayList([]const u8) = .empty;

        for (sourceIds) |sourceId| {
            const diskPath = self.diskPathsBySourceId.get(sourceId) orelse {
                try undeletable.append(allocator, sourceId);
                continue;
            };

            std.Io.Dir.cwd().deleteFile(io, diskPath) catch |err| {
                if (err == error.FileNotFound) {
                    // Already gone, which is the outcome the caller asked for.
                    continue;
                }
                try undeletable.append(allocator, sourceId);
            };
        }

        if (undeletable.items.len > 0) {
            return MediaSourceDeleteError.throw(undeletable.items, "Failed to delete {d} source file(s) from the watched folders.", .{undeletable.items.len});
        }
    }
};
