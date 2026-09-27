//
// Port of exif-parser 0.1.12 (index.js and lib/parser.js): parses the EXIF tags and the image size of a JPEG.
//
// Only what Photosphere uses is ported: `create` over a Node Buffer, `enableSimpleValues` and `parse` with the
// default flags otherwise (tag names resolved, image size read, pointers hidden, binary tags skipped). Not ported:
// lib/simplify.js and lib/date.js (TypeScript turns simple values off), lib/dom-bufferstream.js (for browsers), the
// other flag setters and the thumbnail methods of ExifResult.
//

const std = @import("std");
const serialization_zig = @import("serialization-zig");
const bufferstream = @import("bufferstream.zig");
const jpeg = @import("jpeg.zig");
const exif = @import("exif.zig");
const exif_tags = @import("exif-tags.zig");
const BsonValue = serialization_zig.bson.BsonValue;
const BsonDocument = serialization_zig.bson.BsonDocument;
const BufferStream = bufferstream.BufferStream;
const IImageSize = jpeg.IImageSize;
const ITagValue = exif.ITagValue;

//
// What parse found (TypeScript: ExifResult, only the fields Photosphere reads).
//
pub const ExifResult = struct {
    // The tags, by name, in the order they were first read (TypeScript: a plain object).
    tags: BsonDocument,

    // The size of the image from its SOF section, when it has one.
    imageSize: ?IImageSize,
};

//
// The parser's flags.
//
pub const IParserFlags = struct {
    // Read tags of format 7 (binary).
    readBinaryTags: bool = false,

    // Store tags by name.
    resolveTagNames: bool = true,

    // Turn rationals, GPS degrees and dates into simple values.
    simplifyValues: bool = true,

    // Read the image size from the SOF section.
    imageSize: bool = true,

    // Leave the thumbnail pointer tags out of the tags.
    hidePointers: bool = true,

    // Store the tags at all.
    returnTags: bool = true,
};

//
// The error parse gives for flags whose code was not ported.
//
pub const ParserError = error{FlagNotPorted};

//
// The state passed to the section and tag iterators of parse.
//
const IParseState = struct {
    // Allocates the tags.
    allocator: std.mem.Allocator,

    // The parser's flags.
    flags: IParserFlags,

    // The tags read so far.
    tags: BsonDocument,

    // The image size, when a SOF section was read.
    imageSize: ?IImageSize = null,
};

//
// Parses the EXIF of a JPEG.
//
pub const Parser = struct {
    // The stream over the JPEG.
    stream: BufferStream,

    // The flags.
    flags: IParserFlags,

    //
    // Creates a parser over the bytes of a JPEG (TypeScript: `exifParser.create(buffer)`).
    //
    pub fn create(buffer: []const u8) Parser {
        return .{
            .stream = BufferStream.init(buffer, 0, @intCast(buffer.len), true),
            .flags = .{},
        };
    }

    //
    // Turns simple values on or off.
    //
    pub fn enableSimpleValues(self: *Parser, enable: bool) *Parser {
        self.flags.simplifyValues = enable;
        return self;
    }

    //
    // The tag iterator of the APP1 section.
    //
    fn onTag(state: *IParseState, ifdSection: u8, tagType: u16, value: ITagValue, format: u16) anyerror!void {
        //ignore binary fields if disabled
        if (!state.flags.readBinaryTags and format == 7) {
            return;
        }

        if (tagType == 0x0201 or tagType == 0x0202 or tagType == 0x0103) {
            // Not ported: the thumbnail offset, length and type (read by the thumbnail methods of ExifResult).
            if (state.flags.hidePointers) {
                return;
            }
        }
        //if flag is set to not store tags, return here after storing pointers
        if (!state.flags.returnTags) {
            return;
        }

        const sectionTagNames = if (ifdSection == exif.GPSIFD) exif_tags.gps else exif_tags.exif;
        var name = exif_tags.lookup(sectionTagNames, tagType);
        if (name == null) {
            name = exif_tags.lookup(exif_tags.exif, tagType);
        }
        // A tag with no name is stored under the key "undefined", like `tags[undefined]`.
        const key = name orelse "undefined";
        if (state.tags.get(key) == null) {
            const tagValue: BsonValue = switch (value) {
                .value => |jsValue| jsValue,
                .buffer => |bytes| .{ .binary = .{ .subType = 0, .data = bytes } },
            };
            try state.tags.put(state.allocator, key, tagValue);
        }
    }

    //
    // The section iterator of the JPEG.
    //
    fn onSection(state: *IParseState, sectionType: u8, sectionStream: *BufferStream) anyerror!void {
        if (sectionType == 0xE1) {
            _ = try exif.parseTags(state.allocator, sectionStream, state, onTag);
        }
        else if (state.flags.imageSize) {
            const sectionName = jpeg.getSectionName(sectionType);
            if (sectionName.name != null and std.mem.eql(u8, sectionName.name.?, "SOF")) {
                state.imageSize = try jpeg.getSizeFromSOFSection(sectionStream);
            }
        }
    }

    //
    // Parses the JPEG.
    //
    pub fn parse(self: *Parser, allocator: std.mem.Allocator) !ExifResult {
        if (self.flags.simplifyValues or !self.flags.resolveTagNames) {
            return error.FlagNotPorted;
        }
        const start = self.stream.mark();
        var stream = start.openWithOffset(0);
        var state: IParseState = .{
            .allocator = allocator,
            .flags = self.flags,
            .tags = .{},
        };

        try jpeg.parseSections(&stream, &state, onSection);

        return .{
            .tags = state.tags,
            .imageSize = state.imageSize,
        };
    }
};
