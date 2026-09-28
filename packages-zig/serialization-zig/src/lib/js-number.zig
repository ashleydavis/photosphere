//
// No TypeScript counterpart: the JavaScript number formatting the TypeScript code relies on (`String(number)`).
// It lives in utils-zig's js-number.zig, so the packages below this one can use it too; this re-exports it for the
// packages above (bdb-zig's js-value.zig, merkle-tree-zig and the CLI).
//
pub const writeNumber = @import("utils-zig").js_number.writeNumber;
