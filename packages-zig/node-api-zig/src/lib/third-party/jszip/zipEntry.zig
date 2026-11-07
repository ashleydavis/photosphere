//
// Port of JSZip 3.10.1 lib/zipEntry.js: an entry in the zip file.
//
// JSZip (c) 2009-2016 Stuart Knightley, David Duponchel, Franz Buchinger, António Afonso, MIT license.
//

const std = @import("std");
const utils_zig = @import("utils-zig");
const data_reader = @import("reader/DataReader.zig");
const DataReader = data_reader.DataReader;
const signedShiftRight = data_reader.signedShiftRight;
const utils = @import("utils.zig");
const compressedObject = @import("compressedObject.zig");
const crc32fn = @import("crc32.zig").crc32wrapper;
const utf8 = @import("utf8.zig");
const compressions = @import("compressions.zig");
const errors = utils_zig.errors;
const CompressedObject = compressedObject.CompressedObject;
const ICompression = compressions.ICompression;

//
// The "version made by" of an entry made on DOS.
//
const MADE_BY_DOS = 0x00;

//
// The "version made by" of an entry made on Unix.
//
const MADE_BY_UNIX = 0x03;

//
// Find a compression registered in JSZip.
//
fn findCompression(compressionMethod: []const u8) ?*const ICompression {
    for (compressions.all) |compression| {
        if (std.mem.eql(u8, compression.magic, compressionMethod)) {
            return compression;
        }
    }
    return null;
}

//
// An extra field of an entry.
//
pub const IExtraField = struct {
    // The id of the extra field.
    id: i64,

    // The length of its value.
    length: i64,

    // Its value.
    value: []const u8,
};

//
// An entry in the zip file.
//
pub const ZipEntry = struct {
    // Allocates the decoded names.
    allocator: std.mem.Allocator,

    // Options of the current file (JSZip: `{ zip64 }`).
    zip64: bool,

    // The "version made by" field.
    versionMadeBy: i64 = 0,

    // The general purpose bit flag.
    bitFlag: i64 = 0,

    // The compression method, as stored (two bytes).
    compressionMethod: []const u8 = "",

    // The last modification date (milliseconds since the epoch).
    date: i64 = 0,

    // The crc32 of the uncompressed data.
    crc32: i64 = 0,

    // The size of the compressed data.
    compressedSize: i64 = 0,

    // The size of the uncompressed data.
    uncompressedSize: i64 = 0,

    // The length of the extra fields.
    extraFieldsLength: i64 = 0,

    // The length of the comment.
    fileCommentLength: i64 = 0,

    // The disk the entry starts on.
    diskNumberStart: i64 = 0,

    // The internal file attributes.
    internalFileAttributes: i64 = 0,

    // The external file attributes.
    externalFileAttributes: i64 = 0,

    // Where the local header of the entry is.
    localHeaderOffset: i64 = 0,

    // The extra fields by id (JSZip: an object keyed by the id).
    extraFields: ?std.AutoArrayHashMapUnmanaged(i64, IExtraField) = null,

    // The raw comment.
    fileComment: []const u8 = "",

    // The length of the file name in the local header.
    fileNameLength: i64 = 0,

    // The raw file name, from the local header.
    fileName: []const u8 = "",

    // The decompressed content.
    decompressed: ?CompressedObject = null,

    // The decoded file name.
    fileNameStr: []const u8 = "",

    // The decoded comment.
    fileCommentStr: []const u8 = "",

    // The unix permissions, when the entry was made on unix.
    unixPermissions: ?i64 = null,

    // The DOS permissions, when the entry was made on DOS.
    dosPermissions: ?i64 = null,

    // Whether the entry is a folder.
    dir: bool = false,

    //
    // say if the file is encrypted.
    //
    fn isEncrypted(self: *const ZipEntry) bool {
        // bit 1 is set
        return (self.bitFlag & 0x0001) == 0x0001;
    }

    //
    // say if the file has utf-8 filename/comment.
    //
    fn useUTF8(self: *const ZipEntry) bool {
        // bit 11 is set
        return (self.bitFlag & 0x0800) == 0x0800;
    }

    //
    // Read the local part of a zip file and add the info in this object.
    //
    pub fn readLocalPart(self: *ZipEntry, reader: *DataReader) !void {
        // we already know everything from the central dir !
        // If the central dir data are false, we are doomed.
        // On the bright side, the local part is scary  : zip64, data descriptors, both, etc.
        // The less data we get here, the more reliable this should be.
        // Let's skip the whole header and dash to the data !
        try reader.skip(22);
        // in some zip created on windows, the filename stored in the central dir contains \ instead of /.
        // Strangely, the filename here is OK.
        // I would love to treat these zip files as corrupted (see http://www.info-zip.org/FAQ.html#backslashes
        // or APPNOTE#4.4.17.1, "All slashes MUST be forward slashes '/'") but there are a lot of bad zip generators...
        // Search "unzip mismatching "local" filename continuing with "central" filename version" on
        // the internet.
        //
        // I think I see the logic here : the central directory is used to display
        // content and the local directory is used to extract the files. Mixing / and \
        // may be used to display \ to windows users and use / when extracting the files.
        // Unfortunately, this lead also to some issues : http://seclists.org/fulldisclosure/2009/Sep/394
        self.fileNameLength = try reader.readInt(2);
        const localExtraFieldsLength = try reader.readInt(2); // can't be sure this will be the same as the central dir
        // the fileName is stored as binary data, the handleUTF8 method will take care of the encoding.
        self.fileName = try reader.readData(self.fileNameLength);
        try reader.skip(localExtraFieldsLength);

        if (self.compressedSize == -1 or self.uncompressedSize == -1) {
            return errors.throwError("Bug or corrupted zip : didn't get enough information from the central directory (compressedSize === -1 || uncompressedSize === -1)", .{});
        }

        const compression = findCompression(self.compressionMethod) orelse { // no compression found
            return errors.throwError("Corrupted zip : compression {s} unknown (inner file : {s})", .{ try utils.pretty(self.allocator, self.compressionMethod), self.fileName });
        };
        self.decompressed = .{
            .compressedSize = self.compressedSize,
            .uncompressedSize = self.uncompressedSize,
            .crc32 = self.crc32,
            .compression = compression,
            .compressedContent = try reader.readData(self.compressedSize),
        };
    }

    //
    // Read the central part of a zip file and add the info in this object.
    //
    pub fn readCentralPart(self: *ZipEntry, reader: *DataReader) !void {
        self.versionMadeBy = try reader.readInt(2);
        try reader.skip(2);
        // this.versionNeeded = reader.readInt(2);
        self.bitFlag = try reader.readInt(2);
        self.compressionMethod = try reader.readString(2);
        self.date = try reader.readDate();
        self.crc32 = try reader.readInt(4);
        self.compressedSize = try reader.readInt(4);
        self.uncompressedSize = try reader.readInt(4);
        const fileNameLength = try reader.readInt(2);
        self.extraFieldsLength = try reader.readInt(2);
        self.fileCommentLength = try reader.readInt(2);
        self.diskNumberStart = try reader.readInt(2);
        self.internalFileAttributes = try reader.readInt(2);
        self.externalFileAttributes = try reader.readInt(4);
        self.localHeaderOffset = try reader.readInt(4);

        if (self.isEncrypted()) {
            return errors.throwError("Encrypted zip are not supported", .{});
        }

        // will be read in the local part, see the comments there
        try reader.skip(fileNameLength);
        try self.readExtraFields(reader);
        try self.parseZIP64ExtraField();
        self.fileComment = try reader.readData(self.fileCommentLength);
    }

    //
    // Parse the external file attributes and get the unix/dos permissions.
    //
    pub fn processAttributes(self: *ZipEntry) void {
        self.unixPermissions = null;
        self.dosPermissions = null;
        const madeBy = self.versionMadeBy >> 8;

        // Check if we have the DOS directory flag set.
        // We look for it in the DOS and UNIX permissions
        // but some unknown platform could set it as a compatibility flag.
        self.dir = (self.externalFileAttributes & 0x0010) != 0;

        if (madeBy == MADE_BY_DOS) {
            // first 6 bits (0 to 5)
            self.dosPermissions = self.externalFileAttributes & 0x3F;
        }

        if (madeBy == MADE_BY_UNIX) {
            self.unixPermissions = @as(i64, signedShiftRight(self.externalFileAttributes, 16)) & 0xFFFF;
            // the octal permissions are in (this.unixPermissions & 0x01FF).toString(8);
        }

        // fail safe : if the name ends with a / it probably means a folder
        if (!self.dir and std.mem.endsWith(u8, self.fileNameStr, "/")) {
            self.dir = true;
        }
    }

    //
    // Parse the ZIP64 extra field and merge the info in the current ZipEntry.
    //
    fn parseZIP64ExtraField(self: *ZipEntry) !void {
        const zip64Field = self.extraFields.?.get(0x0001) orelse {
            return;
        };

        // should be something, preparing the extra reader
        var extraReader = DataReader.init(zip64Field.value);

        // I really hope that these 64bits integer can fit in 32 bits integer, because js
        // won't let us have more.
        if (self.uncompressedSize == utils.MAX_VALUE_32BITS) {
            self.uncompressedSize = try extraReader.readInt(8);
        }
        if (self.compressedSize == utils.MAX_VALUE_32BITS) {
            self.compressedSize = try extraReader.readInt(8);
        }
        if (self.localHeaderOffset == utils.MAX_VALUE_32BITS) {
            self.localHeaderOffset = try extraReader.readInt(8);
        }
        if (self.diskNumberStart == utils.MAX_VALUE_32BITS) {
            self.diskNumberStart = try extraReader.readInt(4);
        }
    }

    //
    // Read the central part of a zip file and add the info in this object.
    //
    fn readExtraFields(self: *ZipEntry, reader: *DataReader) !void {
        const end = reader.index + self.extraFieldsLength;

        if (self.extraFields == null) {
            self.extraFields = .empty;
        }

        while (reader.index + 4 < end) {
            const extraFieldId = try reader.readInt(2);
            const extraFieldLength = try reader.readInt(2);
            const extraFieldValue = try reader.readData(extraFieldLength);

            try self.extraFields.?.put(self.allocator, extraFieldId, .{
                .id = extraFieldId,
                .length = extraFieldLength,
                .value = extraFieldValue,
            });
        }

        try reader.setIndex(end);
    }

    //
    // Apply an UTF8 transformation if needed.
    //
    pub fn handleUTF8(self: *ZipEntry) !void {
        if (self.useUTF8()) {
            self.fileNameStr = try utf8.utf8decode(self.allocator, self.fileName);
            self.fileCommentStr = try utf8.utf8decode(self.allocator, self.fileComment);
        }
        else {
            if (try self.findExtraFieldUnicodePath()) |upath| {
                self.fileNameStr = upath;
            }
            else {
                // ASCII text or unsupported code page
                self.fileNameStr = try utf8.utf8decode(self.allocator, self.fileName);
            }

            if (try self.findExtraFieldUnicodeComment()) |ucomment| {
                self.fileCommentStr = ucomment;
            }
            else {
                // ASCII text or unsupported code page
                self.fileCommentStr = try utf8.utf8decode(self.allocator, self.fileComment);
            }
        }
    }

    //
    // Find the unicode path declared in the extra field, if any.
    //
    fn findExtraFieldUnicodePath(self: *ZipEntry) !?[]const u8 {
        if (self.extraFields.?.get(0x7075)) |upathField| {
            var extraReader = DataReader.init(upathField.value);

            // wrong version
            if (try extraReader.readInt(1) != 1) {
                return null;
            }

            // the crc of the filename changed, this field is out of date.
            if (crc32fn(self.fileName) != @as(u32, @truncate(@as(u64, @bitCast(try extraReader.readInt(4)))))) {
                return null;
            }

            return try utf8.utf8decode(self.allocator, try extraReader.readData(upathField.length - 5));
        }
        return null;
    }

    //
    // Find the unicode comment declared in the extra field, if any.
    //
    fn findExtraFieldUnicodeComment(self: *ZipEntry) !?[]const u8 {
        if (self.extraFields.?.get(0x6375)) |ucommentField| {
            var extraReader = DataReader.init(ucommentField.value);

            // wrong version
            if (try extraReader.readInt(1) != 1) {
                return null;
            }

            // the crc of the comment changed, this field is out of date.
            if (crc32fn(self.fileComment) != @as(u32, @truncate(@as(u64, @bitCast(try extraReader.readInt(4)))))) {
                return null;
            }

            return try utf8.utf8decode(self.allocator, try extraReader.readData(ucommentField.length - 5));
        }
        return null;
    }
};
