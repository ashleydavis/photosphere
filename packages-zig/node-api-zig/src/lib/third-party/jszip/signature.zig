//
// Port of JSZip 3.10.1 lib/signature.js: the zip record signatures.
//
// JSZip (c) 2009-2016 Stuart Knightley, David Duponchel, Franz Buchinger, António Afonso, MIT license.
//

//
// The signature of a local file header.
//
pub const LOCAL_FILE_HEADER = "PK\x03\x04";

//
// The signature of a central directory file header.
//
pub const CENTRAL_FILE_HEADER = "PK\x01\x02";

//
// The signature of the end of central directory record.
//
pub const CENTRAL_DIRECTORY_END = "PK\x05\x06";

//
// The signature of the zip64 end of central directory locator.
//
pub const ZIP64_CENTRAL_DIRECTORY_LOCATOR = "PK\x06\x07";

//
// The signature of the zip64 end of central directory record.
//
pub const ZIP64_CENTRAL_DIRECTORY_END = "PK\x06\x06";

// Not ported: DATA_DESCRIPTOR (only used when writing a zip).
