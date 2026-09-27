//
// Port of JSZip 3.10.1 lib/zipEntries.js: all the entries in the zip file.
//
// JSZip (c) 2009-2016 Stuart Knightley, David Duponchel, Franz Buchinger, António Afonso, MIT license.
//

const std = @import("std");
const utils_zig = @import("utils-zig");
const DataReader = @import("reader/DataReader.zig").DataReader;
const utils = @import("utils.zig");
const sig = @import("signature.zig");
const ZipEntry = @import("zipEntry.zig").ZipEntry;
const utf8 = @import("utf8.zig");
const errors = utils_zig.errors;

//
// All the entries in the zip file.
//
pub const ZipEntries = struct {
    // Allocates the entries.
    allocator: std.mem.Allocator,

    // The entries, in central directory order.
    files: std.ArrayList(ZipEntry) = .empty,

    // Reads the zip.
    reader: DataReader = DataReader.init(&.{}),

    // The number of this disk.
    diskNumber: i64 = 0,

    // The disk the central directory starts on.
    diskWithCentralDirStart: i64 = 0,

    // The number of central directory records on this disk.
    centralDirRecordsOnThisDisk: i64 = 0,

    // The number of central directory records.
    centralDirRecords: i64 = 0,

    // The size of the central directory.
    centralDirSize: i64 = 0,

    // Where the central directory starts.
    centralDirOffset: i64 = 0,

    // The length of the zip comment.
    zipCommentLength: i64 = 0,

    // The zip comment.
    zipComment: []const u8 = "",

    // Whether the zip is a zip64 one.
    zip64: bool = false,

    // The size of the zip64 end of central directory record.
    zip64EndOfCentralSize: i64 = 0,

    // The disk the zip64 end of central directory starts on.
    diskWithZip64CentralDirStart: i64 = 0,

    // Where the zip64 end of central directory is.
    relativeOffsetEndOfZip64CentralDir: i64 = 0,

    // The number of disks.
    disksCount: i64 = 0,

    // Not ported: loadOptions (JSZip's defaults are what Photosphere uses: decodeFileName is utf8decode) and
    // zip64ExtensibleData (read and never used).

    //
    // Check that the reader is on the specified signature.
    //
    fn checkSignature(self: *ZipEntries, expectedSignature: []const u8) !void {
        if (!try self.reader.readAndCheckSignature(expectedSignature)) {
            self.reader.index -= 4;
            const signature = try self.reader.readString(4);
            return errors.throwError("Corrupted zip or bug: unexpected signature ({s}, expected {s})", .{ try utils.pretty(self.allocator, signature), try utils.pretty(self.allocator, expectedSignature) });
        }
    }

    //
    // Check if the given signature is at the given index.
    //
    fn isSignature(self: *ZipEntries, askedIndex: i64, expectedSignature: []const u8) !bool {
        const currentIndex = self.reader.index;
        try self.reader.setIndex(askedIndex);
        const signature = try self.reader.readString(4);
        const result = std.mem.eql(u8, signature, expectedSignature);
        try self.reader.setIndex(currentIndex);
        return result;
    }

    //
    // Read the end of the central directory.
    //
    fn readBlockEndOfCentral(self: *ZipEntries) !void {
        self.diskNumber = try self.reader.readInt(2);
        self.diskWithCentralDirStart = try self.reader.readInt(2);
        self.centralDirRecordsOnThisDisk = try self.reader.readInt(2);
        self.centralDirRecords = try self.reader.readInt(2);
        self.centralDirSize = try self.reader.readInt(4);
        self.centralDirOffset = try self.reader.readInt(4);

        self.zipCommentLength = try self.reader.readInt(2);
        // warning : the encoding depends of the system locale
        // On a linux machine with LANG=en_US.utf8, this field is utf8 encoded.
        // On a windows machine, this field is encoded with the localized windows code page.
        const zipComment = try self.reader.readData(self.zipCommentLength);
        // To get consistent behavior with the generation part, we will assume that
        // this is utf8 encoded unless specified otherwise.
        self.zipComment = try utf8.utf8decode(self.allocator, zipComment);
    }

    //
    // Read the end of the Zip 64 central directory.
    // Not merged with the method readEndOfCentral :
    // The end of central can coexist with its Zip64 brother,
    // I don't want to read the wrong number of bytes !
    //
    fn readBlockZip64EndOfCentral(self: *ZipEntries) !void {
        self.zip64EndOfCentralSize = try self.reader.readInt(8);
        try self.reader.skip(4);
        // this.versionMadeBy = this.reader.readString(2);
        // this.versionNeeded = this.reader.readInt(2);
        self.diskNumber = try self.reader.readInt(4);
        self.diskWithCentralDirStart = try self.reader.readInt(4);
        self.centralDirRecordsOnThisDisk = try self.reader.readInt(8);
        self.centralDirRecords = try self.reader.readInt(8);
        self.centralDirSize = try self.reader.readInt(8);
        self.centralDirOffset = try self.reader.readInt(8);

        // (index is never advanced, as in JSZip, so the loop only ends when a read runs past the data.)
        const extraDataSize = self.zip64EndOfCentralSize - 44;
        const index: i64 = 0;
        while (index < extraDataSize) {
            _ = try self.reader.readInt(2);
            const extraFieldLength = try self.reader.readInt(4);
            _ = try self.reader.readData(extraFieldLength);
        }
    }

    //
    // Read the end of the Zip 64 central directory locator.
    //
    fn readBlockZip64EndOfCentralLocator(self: *ZipEntries) !void {
        self.diskWithZip64CentralDirStart = try self.reader.readInt(4);
        self.relativeOffsetEndOfZip64CentralDir = try self.reader.readInt(8);
        self.disksCount = try self.reader.readInt(4);
        if (self.disksCount > 1) {
            return errors.throwError("Multi-volumes zip are not supported", .{});
        }
    }

    //
    // Read the local files, based on the offset read in the central part.
    //
    fn readLocalFiles(self: *ZipEntries) !void {
        for (self.files.items) |*file| {
            try self.reader.setIndex(file.localHeaderOffset);
            try self.checkSignature(sig.LOCAL_FILE_HEADER);
            try file.readLocalPart(&self.reader);
            try file.handleUTF8();
            file.processAttributes();
        }
    }

    //
    // Read the central directory.
    //
    fn readCentralDir(self: *ZipEntries) !void {
        try self.reader.setIndex(self.centralDirOffset);
        while (try self.reader.readAndCheckSignature(sig.CENTRAL_FILE_HEADER)) {
            var file: ZipEntry = .{
                .allocator = self.allocator,
                .zip64 = self.zip64,
            };
            try file.readCentralPart(&self.reader);
            try self.files.append(self.allocator, file);
        }

        if (self.centralDirRecords != @as(i64, @intCast(self.files.items.len))) {
            if (self.centralDirRecords != 0 and self.files.items.len == 0) {
                // We expected some records but couldn't find ANY.
                // This is really suspicious, as if something went wrong.
                return errors.throwError("Corrupted zip or bug: expected {d} records in central dir, got {d}", .{ self.centralDirRecords, self.files.items.len });
            }
            else {
                // We found some records but not all.
                // Something is wrong but we got something for the user: no error here.
                // console.warn("expected", this.centralDirRecords, "records in central dir, got", this.files.length);
            }
        }
    }

    //
    // Read the end of central directory.
    //
    fn readEndOfCentral(self: *ZipEntries) !void {
        var offset = self.reader.lastIndexOfSignature(sig.CENTRAL_DIRECTORY_END);
        if (offset < 0) {
            // Check if the content is a truncated zip or complete garbage.
            // A "LOCAL_FILE_HEADER" is not required at the beginning (auto
            // extractible zip for example) but it can give a good hint.
            // If an ajax request was used without responseType, we will also
            // get unreadable data.
            const isGarbage = !try self.isSignature(0, sig.LOCAL_FILE_HEADER);

            if (isGarbage) {
                return errors.throwError("Can't find end of central directory : is this a zip file ? If it is, see https://stuk.github.io/jszip/documentation/howto/read_zip.html", .{});
            }
            else {
                return errors.throwError("Corrupted zip: can't find end of central directory", .{});
            }
        }
        try self.reader.setIndex(offset);
        const endOfCentralDirOffset = offset;
        try self.checkSignature(sig.CENTRAL_DIRECTORY_END);
        try self.readBlockEndOfCentral();

        // extract from the zip spec :
        //    4)  If one of the fields in the end of central directory
        //        record is too small to hold required data, the field
        //        should be set to -1 (0xFFFF or 0xFFFFFFFF) and the
        //        ZIP64 format record should be created.
        //    5)  The end of central directory record and the
        //        Zip64 end of central directory locator record must
        //        reside on the same disk when splitting or spanning
        //        an archive.
        if (self.diskNumber == utils.MAX_VALUE_16BITS or self.diskWithCentralDirStart == utils.MAX_VALUE_16BITS or self.centralDirRecordsOnThisDisk == utils.MAX_VALUE_16BITS or self.centralDirRecords == utils.MAX_VALUE_16BITS or self.centralDirSize == utils.MAX_VALUE_32BITS or self.centralDirOffset == utils.MAX_VALUE_32BITS) {
            self.zip64 = true;

            // Warning : the zip64 extension is supported, but ONLY if the 64bits integer read from
            // the zip file can fit into a 32bits integer. This cannot be solved : JavaScript represents
            // all numbers as 64-bit double precision IEEE 754 floating point numbers.
            // So, we have 53bits for integers and bitwise operations treat everything as 32bits.
            // see https://developer.mozilla.org/en-US/docs/JavaScript/Reference/Operators/Bitwise_Operators
            // and http://www.ecma-international.org/publications/files/ECMA-ST/ECMA-262.pdf section 8.5

            // should look for a zip64 EOCD locator
            offset = self.reader.lastIndexOfSignature(sig.ZIP64_CENTRAL_DIRECTORY_LOCATOR);
            if (offset < 0) {
                return errors.throwError("Corrupted zip: can't find the ZIP64 end of central directory locator", .{});
            }
            try self.reader.setIndex(offset);
            try self.checkSignature(sig.ZIP64_CENTRAL_DIRECTORY_LOCATOR);
            try self.readBlockZip64EndOfCentralLocator();

            // now the zip64 EOCD record
            if (!try self.isSignature(self.relativeOffsetEndOfZip64CentralDir, sig.ZIP64_CENTRAL_DIRECTORY_END)) {
                // console.warn("ZIP64 end of central directory not where expected.");
                self.relativeOffsetEndOfZip64CentralDir = self.reader.lastIndexOfSignature(sig.ZIP64_CENTRAL_DIRECTORY_END);
                if (self.relativeOffsetEndOfZip64CentralDir < 0) {
                    return errors.throwError("Corrupted zip: can't find the ZIP64 end of central directory", .{});
                }
            }
            try self.reader.setIndex(self.relativeOffsetEndOfZip64CentralDir);
            try self.checkSignature(sig.ZIP64_CENTRAL_DIRECTORY_END);
            try self.readBlockZip64EndOfCentral();
        }

        var expectedEndOfCentralDirOffset = self.centralDirOffset + self.centralDirSize;
        if (self.zip64) {
            expectedEndOfCentralDirOffset += 20; // end of central dir 64 locator
            expectedEndOfCentralDirOffset += 12 + self.zip64EndOfCentralSize; // should not include the leading 12 bytes
        }

        const extraBytes = endOfCentralDirOffset - expectedEndOfCentralDirOffset;

        if (extraBytes > 0) {
            // console.warn(extraBytes, "extra bytes at beginning or within zipfile");
            if (try self.isSignature(endOfCentralDirOffset, sig.CENTRAL_FILE_HEADER)) {
                // The offsets seem wrong, but we have something at the specified offset.
                // So… we keep it.
            }
            else {
                // the offset is wrong, update the "zero" of the reader
                // this happens if data has been prepended (crx files for example)
                self.reader.zero = extraBytes;
            }
        }
        else if (extraBytes < 0) {
            return errors.throwError("Corrupted zip: missing {d} bytes.", .{@abs(extraBytes)});
        }
    }

    //
    // Prepares the reader for the data.
    //
    fn prepareReader(self: *ZipEntries, data: []const u8) void {
        self.reader = DataReader.init(data);
    }

    //
    // Read a zip file and create ZipEntries.
    //
    pub fn load(self: *ZipEntries, data: []const u8) !void {
        self.prepareReader(data);
        try self.readEndOfCentral();
        try self.readCentralDir();
        try self.readLocalFiles();
    }
};
