const std = @import("std");
const serialization_zig = @import("serialization-zig");
const bdb = @import("bdb-zig");
const BsonValue = serialization_zig.bson.BsonValue;
const BsonDocument = serialization_zig.bson.BsonDocument;
const jsonStringifyIndented = bdb.js_value.jsonStringifyIndented;
const writeNumber = serialization_zig.js_number.writeNumber;

//
// No TypeScript counterpart: stands in for the zod schemas the TypeScript tools declare their input with
// (`inputSchema: { assetId: z.string(), ... }`), and for what the MCP TypeScript SDK does with them: the JSON Schema
// that tools/list reports (zod-to-json-schema), and the check of the arguments of tools/call (zod 3 safeParse),
// whose issues become the text of the "Input validation error". Only the zod types the tools use are ported.
//
// The SDK checks the requests themselves with zod 4, whose issues are worded differently; invalidTypeIssue4 builds
// those.
//

//
// The type of a field of a tool's input (the zod type it is declared with).
//
pub const IFieldType = union(enum) {
    // z.string()
    string,

    // z.boolean()
    boolean,

    // z.number().int().min(minimum).max(maximum)
    integer: IIntegerRange,

    // z.array(z.string())
    stringArray,

    // z.enum(values)
    enumeration: []const []const u8,
};

//
// The bounds of an integer field (`.min(minimum).max(maximum)`, both inclusive).
//
pub const IIntegerRange = struct {
    // The smallest value allowed.
    minimum: f64,

    // The largest value allowed.
    maximum: f64,
};

//
// Whether a field may be left out of the arguments, and what it then becomes.
//
pub const IFieldPresence = union(enum) {
    // The field must be given (no modifier).
    required,

    // The field may be left out, and is then left out of the parsed arguments (`.optional()`).
    optional,

    // The field may be left out, and then has this value (`.default(value)`).
    default: BsonValue,
};

//
// One field of a tool's input: an entry of the zod raw shape.
//
pub const IField = struct {
    // The name of the field.
    name: []const u8,

    // The type of the field.
    fieldType: IFieldType,

    // Whether the field may be left out.
    presence: IFieldPresence,
};

//
// The outcome of checking the arguments of a tool call against its input (zod's SafeParseReturnType).
//
pub const IParseResult = union(enum) {
    // The arguments are valid: the parsed arguments, with the defaults filled in and unknown fields dropped.
    success: BsonDocument,

    // The arguments are not valid: the issues zod reports, as the objects it reports them as.
    failure: []const BsonValue,
};

//
// The JSON Schema the SDK reports for a tool whose input has no fields (EMPTY_OBJECT_JSON_SCHEMA).
//
fn emptyObjectJsonSchema(allocator: std.mem.Allocator) !BsonValue {
    var schema: BsonDocument = .empty;
    try schema.put(allocator, "$schema", .{ .string = "http://json-schema.org/draft-07/schema#" });
    try schema.put(allocator, "type", .{ .string = "object" });
    try schema.put(allocator, "properties", .{ .document = .empty });
    return .{ .document = schema };
}

//
// The JSON Schema of one field, like zod-to-json-schema writes it.
//
fn fieldJsonSchema(allocator: std.mem.Allocator, field: IField) !BsonValue {
    var schema: BsonDocument = .empty;
    switch (field.fieldType) {
        .string => {
            try schema.put(allocator, "type", .{ .string = "string" });
        },
        .boolean => {
            try schema.put(allocator, "type", .{ .string = "boolean" });
        },
        .integer => |range| {
            try schema.put(allocator, "type", .{ .string = "integer" });
            try schema.put(allocator, "minimum", .{ .number = range.minimum });
            try schema.put(allocator, "maximum", .{ .number = range.maximum });
        },
        .stringArray => {
            var items: BsonDocument = .empty;
            try items.put(allocator, "type", .{ .string = "string" });
            try schema.put(allocator, "type", .{ .string = "array" });
            try schema.put(allocator, "items", .{ .document = items });
        },
        .enumeration => |values| {
            const valueList = try allocator.alloc(BsonValue, values.len);
            for (values, 0..) |value, valueIndex| {
                valueList[valueIndex] = .{ .string = value };
            }
            try schema.put(allocator, "type", .{ .string = "string" });
            try schema.put(allocator, "enum", .{ .array = valueList });
        },
    }
    switch (field.presence) {
        .default => |defaultValue| {
            try schema.put(allocator, "default", defaultValue);
        },
        .required, .optional => {},
    }
    return .{ .document = schema };
}

//
// The JSON Schema tools/list reports for a tool's input, like the SDK writes it (zod-to-json-schema for an input
// with fields, EMPTY_OBJECT_JSON_SCHEMA for one without).
//
pub fn toJsonSchema(allocator: std.mem.Allocator, shape: []const IField) !BsonValue {
    if (shape.len == 0) {
        return emptyObjectJsonSchema(allocator);
    }

    var properties: BsonDocument = .empty;
    var required: std.ArrayList(BsonValue) = .empty;
    for (shape) |field| {
        try properties.put(allocator, field.name, try fieldJsonSchema(allocator, field));
        if (field.presence == .required) {
            try required.append(allocator, .{ .string = field.name });
        }
    }

    var schema: BsonDocument = .empty;
    try schema.put(allocator, "type", .{ .string = "object" });
    try schema.put(allocator, "properties", .{ .document = properties });
    if (required.items.len > 0) {
        try schema.put(allocator, "required", .{ .array = required.items });
    }
    try schema.put(allocator, "additionalProperties", .{ .boolean = false });
    try schema.put(allocator, "$schema", .{ .string = "http://json-schema.org/draft-07/schema#" });
    return .{ .document = schema };
}

//
// The type zod names for a value in its issues (zod's getParsedType), null standing for undefined.
//
pub fn parsedType(value: ?BsonValue) []const u8 {
    const present = value orelse {
        return "undefined";
    };
    return switch (present) {
        .undefined => "undefined",
        .null => "null",
        .string => "string",
        .number, .int32, .int64, .double => "number",
        .boolean => "boolean",
        .array => "array",
        else => "object",
    };
}

//
// An issue path: the names and indexes that lead to the value an issue is about.
//
fn issuePath(allocator: std.mem.Allocator, elements: []const BsonValue) !BsonValue {
    return .{ .array = try allocator.dupe(BsonValue, elements) };
}

//
// A zod 3 invalid_type issue: `{ code, expected, received, path, message }`, the message being "Required" when the
// value is undefined.
//
fn invalidTypeIssue(allocator: std.mem.Allocator, expected: []const u8, value: ?BsonValue, path: BsonValue) !BsonValue {
    const received = parsedType(value);
    var issue: BsonDocument = .empty;
    try issue.put(allocator, "code", .{ .string = "invalid_type" });
    try issue.put(allocator, "expected", .{ .string = expected });
    try issue.put(allocator, "received", .{ .string = received });
    try issue.put(allocator, "path", path);
    try issue.put(allocator, "message", .{ .string = try invalidTypeMessage(allocator, expected, received) });
    return .{ .document = issue };
}

//
// The message zod 3 gives an invalid_type issue.
//
fn invalidTypeMessage(allocator: std.mem.Allocator, expected: []const u8, received: []const u8) ![]const u8 {
    if (std.mem.eql(u8, received, "undefined")) {
        return "Required";
    }
    return std.fmt.allocPrint(allocator, "Expected {s}, received {s}", .{ expected, received });
}

//
// A zod 4 invalid_type issue, which is how the SDK reports a request whose params do not match the request's schema:
// `{ expected, code, path, message }`.
//
pub fn invalidTypeIssue4(allocator: std.mem.Allocator, expected: []const u8, value: ?BsonValue, path: []const BsonValue) !BsonValue {
    var issue: BsonDocument = .empty;
    try issue.put(allocator, "expected", .{ .string = expected });
    try issue.put(allocator, "code", .{ .string = "invalid_type" });
    try issue.put(allocator, "path", try issuePath(allocator, path));
    try issue.put(allocator, "message", .{ .string = try std.fmt.allocPrint(allocator, "Invalid input: expected {s}, received {s}", .{ expected, parsedType(value) }) });
    return .{ .document = issue };
}

//
// Formats a number the way a JavaScript template string does.
//
fn formatNumber(allocator: std.mem.Allocator, value: f64) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try writeNumber(&output.writer, value);
    return output.written();
}

//
// The values of an enum joined like zod's util.joinValues (`'a' | 'b'`).
//
fn joinValues(allocator: std.mem.Allocator, values: []const []const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    for (values, 0..) |value, valueIndex| {
        if (valueIndex > 0) {
            try output.writer.writeAll(" | ");
        }
        try output.writer.print("'{s}'", .{value});
    }
    return output.written();
}

//
// Appends the issues of an integer field with a number value (zod 3's ZodNumber checks: int, then min, then max;
// every failing check is reported).
//
fn checkInteger(allocator: std.mem.Allocator, issues: *std.ArrayList(BsonValue), range: IIntegerRange, number: f64, path: BsonValue) !void {
    const isInteger = std.math.isFinite(number) and @floor(number) == number;
    if (!isInteger) {
        var issue: BsonDocument = .empty;
        try issue.put(allocator, "code", .{ .string = "invalid_type" });
        try issue.put(allocator, "expected", .{ .string = "integer" });
        try issue.put(allocator, "received", .{ .string = "float" });
        try issue.put(allocator, "message", .{ .string = "Expected integer, received float" });
        try issue.put(allocator, "path", path);
        try issues.append(allocator, .{ .document = issue });
    }
    if (number < range.minimum) {
        var issue: BsonDocument = .empty;
        try issue.put(allocator, "code", .{ .string = "too_small" });
        try issue.put(allocator, "minimum", .{ .number = range.minimum });
        try issue.put(allocator, "type", .{ .string = "number" });
        try issue.put(allocator, "inclusive", .{ .boolean = true });
        try issue.put(allocator, "exact", .{ .boolean = false });
        try issue.put(allocator, "message", .{ .string = try std.fmt.allocPrint(allocator, "Number must be greater than or equal to {s}", .{try formatNumber(allocator, range.minimum)}) });
        try issue.put(allocator, "path", path);
        try issues.append(allocator, .{ .document = issue });
    }
    if (number > range.maximum) {
        var issue: BsonDocument = .empty;
        try issue.put(allocator, "code", .{ .string = "too_big" });
        try issue.put(allocator, "maximum", .{ .number = range.maximum });
        try issue.put(allocator, "type", .{ .string = "number" });
        try issue.put(allocator, "inclusive", .{ .boolean = true });
        try issue.put(allocator, "exact", .{ .boolean = false });
        try issue.put(allocator, "message", .{ .string = try std.fmt.allocPrint(allocator, "Number must be less than or equal to {s}", .{try formatNumber(allocator, range.maximum)}) });
        try issue.put(allocator, "path", path);
        try issues.append(allocator, .{ .document = issue });
    }
}

//
// Appends the issues of an enum field (zod 3's ZodEnum).
//
fn checkEnumeration(allocator: std.mem.Allocator, issues: *std.ArrayList(BsonValue), values: []const []const u8, value: ?BsonValue, path: BsonValue) !void {
    const text = if (value != null and value.? == .string) value.?.string else {
        const expected = try joinValues(allocator, values);
        const received = parsedType(value);
        var issue: BsonDocument = .empty;
        try issue.put(allocator, "expected", .{ .string = expected });
        try issue.put(allocator, "received", .{ .string = received });
        try issue.put(allocator, "code", .{ .string = "invalid_type" });
        try issue.put(allocator, "path", path);
        try issue.put(allocator, "message", .{ .string = try invalidTypeMessage(allocator, expected, received) });
        try issues.append(allocator, .{ .document = issue });
        return;
    };
    for (values) |allowed| {
        if (std.mem.eql(u8, allowed, text)) {
            return;
        }
    }
    const options = try allocator.alloc(BsonValue, values.len);
    for (values, 0..) |allowed, valueIndex| {
        options[valueIndex] = .{ .string = allowed };
    }
    var issue: BsonDocument = .empty;
    try issue.put(allocator, "received", .{ .string = text });
    try issue.put(allocator, "code", .{ .string = "invalid_enum_value" });
    try issue.put(allocator, "options", .{ .array = options });
    try issue.put(allocator, "path", path);
    try issue.put(allocator, "message", .{ .string = try std.fmt.allocPrint(allocator, "Invalid enum value. Expected {s}, received '{s}'", .{ try joinValues(allocator, values), text }) });
    try issues.append(allocator, .{ .document = issue });
}

//
// Appends the issues of one field's value (null standing for undefined) and returns whether it is valid.
//
fn checkField(allocator: std.mem.Allocator, issues: *std.ArrayList(BsonValue), field: IField, value: ?BsonValue) !bool {
    const issueCount = issues.items.len;
    const path = try issuePath(allocator, &.{.{ .string = field.name }});
    switch (field.fieldType) {
        .string => {
            if (value == null or value.? != .string) {
                try issues.append(allocator, try invalidTypeIssue(allocator, "string", value, path));
            }
        },
        .boolean => {
            if (value == null or value.? != .boolean) {
                try issues.append(allocator, try invalidTypeIssue(allocator, "boolean", value, path));
            }
        },
        .integer => |range| {
            if (value == null or value.? != .number) {
                try issues.append(allocator, try invalidTypeIssue(allocator, "number", value, path));
            }
            else {
                try checkInteger(allocator, issues, range, value.?.number, path);
            }
        },
        .stringArray => {
            if (value == null or value.? != .array) {
                try issues.append(allocator, try invalidTypeIssue(allocator, "array", value, path));
            }
            else {
                for (value.?.array, 0..) |element, elementIndex| {
                    if (element != .string) {
                        const elementPath = try issuePath(allocator, &.{ .{ .string = field.name }, .{ .number = @floatFromInt(elementIndex) } });
                        try issues.append(allocator, try invalidTypeIssue(allocator, "string", element, elementPath));
                    }
                }
            }
        },
        .enumeration => |values| {
            try checkEnumeration(allocator, issues, values, value, path);
        },
    }
    return issues.items.len == issueCount;
}

//
// Checks the arguments of a tool call against the tool's input, like the SDK's validateToolInput (zod 3 safeParse
// of `z.object(shape)`). `arguments` is null when the call has none (undefined). An input without fields is an
// object schema of zod 4 in the SDK, so its one possible issue is worded the zod 4 way.
//
pub fn parseArguments(allocator: std.mem.Allocator, shape: []const IField, arguments: ?BsonDocument) !IParseResult {
    var issues: std.ArrayList(BsonValue) = .empty;
    const input = arguments orelse {
        if (shape.len == 0) {
            try issues.append(allocator, try invalidTypeIssue4(allocator, "object", null, &.{}));
        }
        else {
            try issues.append(allocator, try invalidTypeIssue(allocator, "object", null, try issuePath(allocator, &.{})));
        }
        return .{ .failure = issues.items };
    };

    var parsed: BsonDocument = .empty;
    for (shape) |field| {
        const value = input.get(field.name);
        if (value == null) {
            switch (field.presence) {
                .optional => {
                    continue;
                },
                .default => |defaultValue| {
                    try parsed.put(allocator, field.name, defaultValue);
                    continue;
                },
                .required => {},
            }
        }
        if (try checkField(allocator, &issues, field, value)) {
            try parsed.put(allocator, field.name, value.?);
        }
    }
    if (issues.items.len > 0) {
        return .{ .failure = issues.items };
    }
    return .{ .success = parsed };
}

//
// Formats issues the way the SDK puts them in an error message (getParseErrorMessage:
// `JSON.stringify(error.issues, null, 2)`).
//
pub fn formatIssues(allocator: std.mem.Allocator, issues: []const BsonValue) ![]const u8 {
    return jsonStringifyIndented(allocator, .{ .array = @constCast(issues) });
}
