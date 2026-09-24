//
// Port of the parts of the third-party `commander` package (v13.1.0) that parse the `replicate` and
// `verify` command lines (this file has no TypeScript counterpart in the repo): option flag parsing,
// `Command.parseOptions`, the error messages and the "Did you mean" suggestions.
// Help output is not ported: index.zig hands help requests to the TypeScript CLI.
//

const std = @import("std");
const storage_zig = @import("storage-zig");
const localeLessThan = storage_zig.locale_compare.lessThan;

//
// An option as declared in index.ts: the flags, the description and an optional default
// (TypeScript: the `[flags, description, default?]` tuples passed to `.option(...)`).
//
pub const OptionSpec = struct {
    // The flags, e.g. "-k, --key <keyfile>".
    flags: []const u8,

    // The help text.
    description: []const u8,

    // The default value of a boolean option (the third tuple element), or null when there is none.
    defaultValue: ?bool = null,
};

//
// A parsed option declaration (commander `Option`).
//
pub const Option = struct {
    // The flags as declared.
    flags: []const u8,

    // The help text.
    description: []const u8,

    // The short flag ("-k", or "--dk" for a pair of long flags), or null.
    short: ?[]const u8,

    // The long flag ("--key"), or null.
    long: ?[]const u8,

    // True when the option takes a required value (`<value>`).
    required: bool,

    // True when the option takes an optional value (`[value]`).
    optional: bool,

    // The default value of a boolean option.
    defaultValue: ?bool,

    //
    // Parses the flags of an option declaration (commander `splitOptionFlags` and the Option constructor).
    //
    pub fn init(spec: OptionSpec) Option {
        var parts: [8][]const u8 = undefined;
        var count: usize = 0;
        var iterator = std.mem.tokenizeAny(u8, spec.flags, " |,");
        while (iterator.next()) |part| {
            if (count < parts.len - 1) {
                parts[count] = part;
                count += 1;
            }
        }
        parts[count] = "guard";

        var index: usize = 0;
        var shortFlag: ?[]const u8 = null;
        var longFlag: ?[]const u8 = null;
        // Normal is short and/or long.
        if (isShortFlag(parts[index])) {
            shortFlag = parts[index];
            index += 1;
        }
        if (isLongFlag(parts[index])) {
            longFlag = parts[index];
            index += 1;
        }
        // Long then short. Rarely used but fine.
        if (shortFlag == null and isShortFlag(parts[index])) {
            shortFlag = parts[index];
            index += 1;
        }
        // Allow two long flags, like '--ws, --workspace'
        // This is the supported way to have a shortish option flag.
        if (shortFlag == null and isLongFlag(parts[index])) {
            shortFlag = longFlag;
            longFlag = parts[index];
            index += 1;
        }

        return .{
            .flags = spec.flags,
            .description = spec.description,
            .short = shortFlag,
            .long = longFlag,
            .required = std.mem.indexOfScalar(u8, spec.flags, '<') != null,
            .optional = std.mem.indexOfScalar(u8, spec.flags, '[') != null,
            .defaultValue = spec.defaultValue,
        };
    }

    //
    // True for a short flag (/^-[^-]$/).
    //
    fn isShortFlag(part: []const u8) bool {
        return part.len == 2 and part[0] == '-' and part[1] != '-';
    }

    //
    // True for a long flag (/^--[^-]/).
    //
    fn isLongFlag(part: []const u8) bool {
        return part.len >= 3 and part[0] == '-' and part[1] == '-' and part[2] != '-';
    }

    //
    // True when the argument is one of the option's flags.
    //
    pub fn is(self: Option, arg: []const u8) bool {
        if (self.short) |shortFlag| {
            if (std.mem.eql(u8, shortFlag, arg)) {
                return true;
            }
        }
        if (self.long) |longFlag| {
            if (std.mem.eql(u8, longFlag, arg)) {
                return true;
            }
        }
        return false;
    }

    //
    // The name of the option: the long flag without "--", else the short flag without "-".
    //
    pub fn name(self: Option) []const u8 {
        if (self.long) |longFlag| {
            return longFlag[2..];
        }
        return self.short.?[1..];
    }

    //
    // The key of the option in the parsed values: the name in camel case ("dest-key" -> "destKey").
    //
    pub fn attributeName(self: Option, allocator: std.mem.Allocator) ![]const u8 {
        const optionName = self.name();
        var result: std.ArrayList(u8) = .empty;
        var upper_next = false;
        for (optionName) |character| {
            if (character == '-') {
                upper_next = true;
                continue;
            }
            try result.append(allocator, if (upper_next) std.ascii.toUpper(character) else character);
            upper_next = false;
        }
        return result.items;
    }
};

//
// A parsed option value: true for a flag, or the text of an option with a value.
//
pub const OptionValue = union(enum) {
    // A boolean flag.
    flag: bool,

    // The value of an option with a value.
    text: []const u8,
};

//
// The option values of a command, by attribute name (commander `opts()`).
//
pub const OptionValues = std.StringArrayHashMapUnmanaged(OptionValue);

//
// The arguments that are not options (commander `parseOptions` result).
//
pub const ParseOptionsResult = struct {
    // Operands: the arguments that are not options or option values.
    operands: []const []const u8,

    // The first unknown option and every argument after it.
    unknown: []const []const u8,
};

//
// A commander error: the message printed to stderr and its code (the process exits with 1).
//
pub const CommanderError = struct {
    // The error message (without the trailing newline).
    message: []const u8,

    // The commander error code (e.g. "commander.unknownOption").
    code: []const u8,
};

//
// The outcome of parseOptions: the arguments, or the error that stops parsing.
//
pub const ParseOptionsOutcome = union(enum) {
    // Parsing succeeded.
    parsed: ParseOptionsResult,

    // An option is missing its value (commander `optionMissingArgument`).
    failure: CommanderError,
};

//
// Finds the option matching the argument (commander `_findOption`).
//
fn findOption(options: []const Option, arg: []const u8) ?Option {
    for (options) |option| {
        if (option.is(arg)) {
            return option;
        }
    }
    return null;
}

//
// True when the argument could be an option (`arg.length > 1 && arg[0] === '-'`).
//
fn maybeOption(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '-';
}

//
// Records the value of an option (commander's `option:<name>` listener, without custom processing).
//
fn setOptionValue(allocator: std.mem.Allocator, values: *OptionValues, option: Option, value: ?[]const u8) !void {
    const key = try option.attributeName(allocator);
    if (value) |text| {
        try values.put(allocator, key, .{ .text = text });
    }
    else {
        try values.put(allocator, key, .{ .flag = true });
    }
}

//
// Parses options from argv, removing known options, and returns the operands and unknown arguments
// (commander `Command.parseOptions`). Known option values are stored in `values`.
//
pub fn parseOptions(allocator: std.mem.Allocator, options: []const Option, argv: []const []const u8, values: *OptionValues) !ParseOptionsOutcome {
    var operands: std.ArrayList([]const u8) = .empty;
    var unknown: std.ArrayList([]const u8) = .empty;
    var dest_is_unknown = false;
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(allocator, argv);

    // parse options
    while (args.items.len > 0) {
        const arg = args.orderedRemove(0);
        const dest = if (dest_is_unknown) &unknown else &operands;

        // literal
        if (std.mem.eql(u8, arg, "--")) {
            if (dest_is_unknown) {
                try dest.append(allocator, arg);
            }
            try dest.appendSlice(allocator, args.items);
            break;
        }

        if (maybeOption(arg)) {
            // recognised option, call listener to assign value with possible custom processing
            if (findOption(options, arg)) |option| {
                if (option.required) {
                    if (args.items.len == 0) {
                        return .{ .failure = .{
                            .message = try std.fmt.allocPrint(allocator, "error: option '{s}' argument missing", .{option.flags}),
                            .code = "commander.optionMissingArgument",
                        } };
                    }
                    const value = args.orderedRemove(0);
                    try setOptionValue(allocator, values, option, value);
                }
                else if (option.optional) {
                    // historical behaviour is optional value is following arg unless an option
                    var value: ?[]const u8 = null;
                    if (args.items.len > 0 and !maybeOption(args.items[0])) {
                        value = args.orderedRemove(0);
                    }
                    try setOptionValue(allocator, values, option, value);
                }
                else {
                    // boolean flag
                    try setOptionValue(allocator, values, option, null);
                }
                continue;
            }
        }

        // Look for combo options following single dash, eat first one if known.
        if (arg.len > 2 and arg[0] == '-' and arg[1] != '-') {
            const short = try std.fmt.allocPrint(allocator, "-{c}", .{arg[1]});
            if (findOption(options, short)) |option| {
                if (option.required) {
                    // option with value following in same argument
                    try setOptionValue(allocator, values, option, arg[2..]);
                }
                else {
                    // boolean option, emit and put back remainder of arg for further processing
                    try setOptionValue(allocator, values, option, null);
                    try args.insert(allocator, 0, try std.fmt.allocPrint(allocator, "-{s}", .{arg[2..]}));
                }
                continue;
            }
        }

        // Look for known long flag with value, like --foo=bar
        if (arg.len > 3 and std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |equals_index| {
                if (equals_index > 2) {
                    if (findOption(options, arg[0..equals_index])) |option| {
                        if (option.required or option.optional) {
                            try setOptionValue(allocator, values, option, arg[equals_index + 1 ..]);
                            continue;
                        }
                    }
                }
            }
        }

        // Not a recognised option by this command.
        // Might be a command-argument, or subcommand option, or unknown option, or help command or option.

        // An unknown option means further arguments also classified as unknown so can be reprocessed by subcommands.
        if (maybeOption(arg)) {
            dest_is_unknown = true;
        }

        // add arg
        if (dest_is_unknown) {
            try unknown.append(allocator, arg);
        }
        else {
            try operands.append(allocator, arg);
        }
    }

    return .{ .parsed = .{ .operands = operands.items, .unknown = unknown.items } };
}

//
// The maximum edit distance of a suggestion.
//
const maxDistance = 3;

//
// The optimal string alignment distance (Damerau-Levenshtein, no substring edited more than once).
//
pub fn editDistance(allocator: std.mem.Allocator, first: []const u8, second: []const u8) !usize {
    // Quick early exit, return worst case.
    const length_difference = if (first.len > second.len) first.len - second.len else second.len - first.len;
    if (length_difference > maxDistance) {
        return @max(first.len, second.len);
    }

    // distance between prefix substrings of first and second
    const columns = second.len + 1;
    const distances = try allocator.alloc(usize, (first.len + 1) * columns);
    defer allocator.free(distances);

    // pure deletions turn first into empty string
    var row: usize = 0;
    while (row <= first.len) {
        distances[row * columns] = row;
        row += 1;
    }
    // pure insertions turn empty string into second
    var column: usize = 0;
    while (column <= second.len) {
        distances[column] = column;
        column += 1;
    }

    // fill matrix
    column = 1;
    while (column <= second.len) {
        row = 1;
        while (row <= first.len) {
            const cost: usize = if (first[row - 1] == second[column - 1]) 0 else 1;
            distances[row * columns + column] = @min(
                distances[(row - 1) * columns + column] + 1, // deletion
                distances[row * columns + column - 1] + 1, // insertion
                distances[(row - 1) * columns + column - 1] + cost, // substitution
            );
            // transposition
            if (row > 1 and column > 1 and first[row - 1] == second[column - 2] and first[row - 2] == second[column - 1]) {
                distances[row * columns + column] = @min(distances[row * columns + column], distances[(row - 2) * columns + column - 2] + 1);
            }
            row += 1;
        }
        column += 1;
    }

    return distances[first.len * columns + second.len];
}

//
// Find close matches, restricted to same number of edits.
// Returns "" or "\n(Did you mean ...?)".
//
pub fn suggestSimilar(allocator: std.mem.Allocator, word: []const u8, candidates: []const []const u8) ![]const u8 {
    if (candidates.len == 0) {
        return "";
    }
    // remove possible duplicates
    var unique: std.ArrayList([]const u8) = .empty;
    for (candidates) |candidate| {
        var seen = false;
        for (unique.items) |existing| {
            if (std.mem.eql(u8, existing, candidate)) {
                seen = true;
                break;
            }
        }
        if (!seen) {
            try unique.append(allocator, candidate);
        }
    }

    const searchingOptions = std.mem.startsWith(u8, word, "--");
    const searchWord = if (searchingOptions) word[2..] else word;

    var similar: std.ArrayList([]const u8) = .empty;
    var bestDistance: usize = maxDistance;
    const minSimilarity = 0.4;
    for (unique.items) |fullCandidate| {
        const candidate = if (searchingOptions and fullCandidate.len >= 2) fullCandidate[2..] else fullCandidate;
        if (candidate.len <= 1) {
            continue; // no one character guesses
        }

        const distance = try editDistance(allocator, searchWord, candidate);
        const length = @max(searchWord.len, candidate.len);
        const similarity = (@as(f64, @floatFromInt(length)) - @as(f64, @floatFromInt(distance))) / @as(f64, @floatFromInt(length));
        if (similarity > minSimilarity) {
            if (distance < bestDistance) {
                // better edit distance, throw away previous worse matches
                bestDistance = distance;
                similar.clearRetainingCapacity();
                try similar.append(allocator, candidate);
            }
            else if (distance == bestDistance) {
                try similar.append(allocator, candidate);
            }
        }
    }

    std.mem.sort([]const u8, similar.items, {}, localeLessThan);
    var shown: std.ArrayList([]const u8) = .empty;
    for (similar.items) |candidate| {
        try shown.append(allocator, if (searchingOptions) try std.fmt.allocPrint(allocator, "--{s}", .{candidate}) else candidate);
    }

    if (shown.items.len > 1) {
        return std.fmt.allocPrint(allocator, "\n(Did you mean one of {s}?)", .{try std.mem.join(allocator, ", ", shown.items)});
    }
    if (shown.items.len == 1) {
        return std.fmt.allocPrint(allocator, "\n(Did you mean {s}?)", .{shown.items[0]});
    }
    return "";
}

//
// The error for an unknown option (commander `unknownOption`), with suggestions from the long flags of
// the command, its help option and its parent's options (candidateFlags).
//
pub fn unknownOptionError(allocator: std.mem.Allocator, flag: []const u8, candidateFlags: []const []const u8) !CommanderError {
    var suggestion: []const u8 = "";
    if (std.mem.startsWith(u8, flag, "--")) {
        suggestion = try suggestSimilar(allocator, flag, candidateFlags);
    }
    return .{
        .message = try std.fmt.allocPrint(allocator, "error: unknown option '{s}'{s}", .{ flag, suggestion }),
        .code = "commander.unknownOption",
    };
}

//
// The error for arguments given to a command that takes none (commander `_excessArguments`).
//
pub fn excessArgumentsError(allocator: std.mem.Allocator, commandName: []const u8, expected: usize, receivedCount: usize) !CommanderError {
    const plural = if (expected == 1) "" else "s";
    return .{
        .message = try std.fmt.allocPrint(allocator, "error: too many arguments for '{s}'. Expected {d} argument{s} but got {d}.", .{ commandName, expected, plural, receivedCount }),
        .code = "commander.excessArguments",
    };
}
