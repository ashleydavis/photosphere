pub const serialization = @import("lib/serialization.zig");
pub const bson = @import("lib/bson.zig");
pub const json_parse = @import("lib/json-parse.zig");
pub const js_date = @import("lib/js-date.zig");
pub const js_number = @import("lib/js-number.zig");

//
// The zlib API of zlib-ng (translated from its zlib.h), built by this package, for the packages that decompress
// with it too.
//
pub const zlib = @import("zlib");
