//
// The JavaScript Date semantics that the stored data depends on (`new Date(string)`, `Date.prototype.toISOString`,
// `Date.prototype.toString`). They live in utils-zig's js-date.zig, so the packages below this one can use them too; this
// re-exports them for the packages above (bdb-zig's js-value.zig, api-zig, node-api-zig and tools-zig).
//
const js_date = @import("utils-zig").js_date;

// The largest absolute time value a JavaScript Date holds.
pub const MAX_TIME_VALUE = js_date.MAX_TIME_VALUE;

// Returns true when a time value is a valid JS Date.
pub const isValidTime = js_date.isValidTime;

// Converts a UTC calendar date to days since 1970-01-01.
pub const daysFromCivil = js_date.daysFromCivil;

// Formats a time value like `Date.prototype.toISOString()`.
pub const writeIsoString = js_date.writeIsoString;

// Formats a time value like `Date.prototype.toString()`.
pub const writeDateString = js_date.writeDateString;

// Formats a time value like `Date.prototype.toLocaleDateString()`.
pub const writeLocaleDateString = js_date.writeLocaleDateString;

// Parses text like `new Date(text)`.
pub const parseDate = js_date.parseDate;
