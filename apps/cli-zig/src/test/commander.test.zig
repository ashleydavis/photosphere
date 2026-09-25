const std = @import("std");
const cli = @import("cli-zig");
const helpers = @import("test-helpers.zig");
const commander = cli.commander;
const Command = commander.Command;
const Option = commander.Option;
const Argument = commander.Argument;
const OptionValue = commander.OptionValue;
const OptionValues = commander.OptionValues;
const ArgumentValue = commander.ArgumentValue;
const Help = commander.Help;

//
// The help width the test output reports (commander's `getOutHelpWidth`), set per fixture program.
//
var testHelpWidth: ?usize = null;

//
// Whether the test output reports that it shows colors (commander's `getOutHasColors`), set per fixture program.
//
var testColors = false;

//
// Reports the help width of the test output.
//
fn reportHelpWidth() ?usize {
    return testHelpWidth;
}

//
// Reports whether the test output shows colors.
//
fn reportColors() bool {
    return testColors;
}

//
// Where a test program writes, and what its hooks, actions and option parsers record.
//
const IRecorder = struct {
    // Allocates the recorded events.
    allocator: std.mem.Allocator,

    // Captures stdout.
    stdout: std.Io.Writer.Allocating,

    // Captures stderr.
    stderr: std.Io.Writer.Allocating,

    // The recorded events, each one a JSON object.
    events: std.ArrayList([]const u8) = .empty,

    //
    // The output configuration that writes to the captures.
    //
    fn output(self: *IRecorder) commander.IOutputConfiguration {
        return .{
            .writeOut = &self.stdout.writer,
            .writeErr = &self.stderr.writer,
            .getOutHelpWidth = reportHelpWidth,
            .getErrHelpWidth = reportHelpWidth,
            .getOutHasColors = reportColors,
            .getErrHasColors = reportColors,
        };
    }
};

//
// Creates a recorder.
//
fn createRecorder(allocator: std.mem.Allocator) IRecorder {
    return .{
        .allocator = allocator,
        .stdout = std.Io.Writer.Allocating.init(allocator),
        .stderr = std.Io.Writer.Allocating.init(allocator),
    };
}

//
// The context of a recording option parser: the recorder and the flags of the option.
//
const IParserContext = struct {
    // Where the call is recorded.
    recorder: *IRecorder,

    // The flags of the option.
    flags: []const u8,
};

//
// Writes an option value as JSON.
//
fn writeOptionValue(stringify: *std.json.Stringify, value: ?OptionValue) !void {
    if (value) |present| {
        switch (present) {
            .boolean => |flag| try stringify.write(flag),
            .string => |text| try stringify.write(text),
        }
    }
    else {
        try stringify.write(null);
    }
}

//
// Writes option values as a JSON object.
//
fn writeOptionValues(stringify: *std.json.Stringify, values: *const OptionValues) !void {
    try stringify.beginObject();
    var iterator = values.iterator();
    while (iterator.next()) |entry| {
        try stringify.objectField(entry.key_ptr.*);
        try writeOptionValue(stringify, entry.value_ptr.*);
    }
    try stringify.endObject();
}

//
// Records a call of the preAction hook: the command it was added to, the command whose action runs and the
// option values of the first.
//
fn recordHook(recorder: *IRecorder, thisCommand: *Command, actionCommand: *Command) !void {
    var json = std.Io.Writer.Allocating.init(recorder.allocator);
    var stringify: std.json.Stringify = .{
        .writer = &json.writer,
    };
    try stringify.beginObject();
    try stringify.objectField("hook");
    try stringify.write(thisCommand.getName());
    try stringify.objectField("actionCommand");
    try stringify.write(actionCommand.getName());
    try stringify.objectField("opts");
    try writeOptionValues(&stringify, thisCommand.opts());
    try stringify.endObject();
    try recorder.events.append(recorder.allocator, json.written());
}

//
// Records a call of an action: the command, the processed arguments and the option values.
//
fn recordAction(recorder: *IRecorder, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    var json = std.Io.Writer.Allocating.init(recorder.allocator);
    var stringify: std.json.Stringify = .{
        .writer = &json.writer,
    };
    try stringify.beginObject();
    try stringify.objectField("action");
    try stringify.write(command.getName());
    try stringify.objectField("args");
    try stringify.beginArray();
    for (args) |arg| {
        switch (arg) {
            .none => try stringify.write(null),
            .string => |text| try stringify.write(text),
            .list => |list| try stringify.write(list),
        }
    }
    try stringify.endArray();
    try stringify.objectField("opts");
    try writeOptionValues(&stringify, options);
    try stringify.endObject();
    try recorder.events.append(recorder.allocator, json.written());
}

//
// An option parser that records its call and returns "parsed:<value>".
//
fn recordParser(context: *IParserContext, value: ?[]const u8, previous: ?OptionValue) !?OptionValue {
    const recorder = context.recorder;
    var json = std.Io.Writer.Allocating.init(recorder.allocator);
    var stringify: std.json.Stringify = .{
        .writer = &json.writer,
    };
    try stringify.beginObject();
    try stringify.objectField("parser");
    try stringify.write(context.flags);
    try stringify.objectField("value");
    try stringify.write(value);
    try stringify.objectField("previous");
    try writeOptionValue(&stringify, previous);
    try stringify.endObject();
    try recorder.events.append(recorder.allocator, json.written());
    return .{
        .string = try std.fmt.allocPrint(recorder.allocator, "parsed:{s}", .{value orelse "undefined"}),
    };
}

//
// An option parser that fails (the fixture's parser that throws "parser failed").
//
fn throwingParser(context: *IParserContext, value: ?[]const u8, previous: ?OptionValue) !?OptionValue {
    _ = context;
    _ = value;
    _ = previous;
    return error.ParserFailed;
}

//
// Converts a JSON default value (boolean or string) to an option value.
//
fn defaultFromJson(value: ?std.json.Value) ?OptionValue {
    const present = value orelse return null;
    return switch (present) {
        .bool => |flag| .{
            .boolean = flag,
        },
        .string => |text| .{
            .string = text,
        },
        else => unreachable,
    };
}

//
// Converts a help text position name to the enum.
//
fn positionFromName(name: []const u8) commander.HelpTextPosition {
    return std.meta.stringToEnum(commander.HelpTextPosition, name).?;
}

//
// Builds a command from its fixture definition, like buildCommand in generate.ts.
//
fn buildCommand(allocator: std.mem.Allocator, command: *Command, definition: std.json.ObjectMap, recorder: *IRecorder) !void {
    if (definition.get("description")) |description| {
        _ = command.description(description.string);
    }
    if (definition.get("aliases")) |aliases| {
        for (aliases.array.items) |aliasName| {
            _ = command.alias(aliasName.string);
        }
    }
    if (definition.get("arguments")) |arguments| {
        for (arguments.array.items) |argument| {
            _ = command.argument(helpers.stringField(argument, "name"), helpers.stringField(argument, "description"));
        }
    }
    if (definition.get("options")) |options| {
        for (options.array.items) |optionDefinition| {
            const flags = helpers.stringField(optionDefinition, "flags");
            const optionDescription = helpers.stringField(optionDefinition, "description");
            const defaultValue = defaultFromJson(optionDefinition.object.get("defaultValue"));
            const mandatory = optionDefinition.object.get("mandatory") != null;
            if (optionDefinition.object.get("parser")) |parser| {
                const context = try allocator.create(IParserContext);
                context.* = .{
                    .recorder = recorder,
                    .flags = flags,
                };
                try std.testing.expect(!mandatory);
                try std.testing.expect(defaultValue == null);
                if (std.mem.eql(u8, parser.string, "record")) {
                    _ = command.optionWithArgParser(flags, optionDescription, context, recordParser);
                }
                else {
                    _ = command.optionWithArgParser(flags, optionDescription, context, throwingParser);
                }
            }
            else if (mandatory) {
                _ = command.requiredOption(flags, optionDescription, defaultValue);
            }
            else {
                _ = command.option(flags, optionDescription, defaultValue);
            }
        }
    }
    if (definition.get("helpTexts")) |helpTexts| {
        for (helpTexts.array.items) |helpText| {
            _ = command.addHelpText(positionFromName(helpers.stringField(helpText, "position")), helpers.stringField(helpText, "text"));
        }
    }
    if (definition.get("exitOverride") != null) {
        _ = command.exitOverride();
    }
    if (definition.get("addHelpCommand")) |enable| {
        _ = command.addHelpCommand(enable.bool);
    }
    if (definition.get("preActionHook") != null) {
        _ = command.hook(.preAction, recorder, recordHook);
    }
    if (definition.get("action") != null) {
        _ = command.action(recorder, recordAction);
    }
    if (definition.get("commands")) |commands| {
        for (commands.array.items) |subDefinition| {
            const subName = helpers.stringField(subDefinition, "name");
            const attach = subDefinition.object.get("attach");
            var subcommand: *Command = undefined;
            if (attach != null and std.mem.eql(u8, attach.?.string, "addCommand")) {
                subcommand = Command.init(allocator, subName);
                _ = subcommand.configureOutput(recorder.output());
                _ = command.addCommand(subcommand);
            }
            else {
                subcommand = command.command(subName, .{
                    .hidden = subDefinition.object.get("hidden") != null,
                });
            }
            try buildCommand(allocator, subcommand, subDefinition.object, recorder);
        }
    }
}

//
// The result of a parse, as the fixture records it.
//
fn describeResult(allocator: std.mem.Allocator, program: *Command, outcome: anyerror!void) ![]const u8 {
    var json = std.Io.Writer.Allocating.init(allocator);
    var stringify: std.json.Stringify = .{
        .writer = &json.writer,
    };
    try stringify.beginObject();
    try stringify.objectField("kind");
    if (outcome) |_| {
        try stringify.write("ok");
    }
    else |err| {
        if (err == error.CommanderError) {
            const details = program.getCommanderError().?;
            try stringify.write("commanderError");
            try stringify.objectField("exitCode");
            try stringify.write(details.exitCode);
            try stringify.objectField("code");
            try stringify.write(details.code);
            try stringify.objectField("message");
            try stringify.write(details.message);
        }
        else if (err == error.Exit) {
            try stringify.write("exit");
            try stringify.objectField("exitCode");
            try stringify.write(program.getCommanderError().?.exitCode);
        }
        else if (err == error.ParserFailed) {
            try stringify.write("thrown");
            try stringify.objectField("message");
            try stringify.write("parser failed");
        }
        else {
            return err;
        }
    }
    try stringify.endObject();
    return json.written();
}

test "programs parse and render help exactly like commander.js" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try helpers.loadFixture(allocator, "commander/programs.json");
    var caseCount: usize = 0;
    for (fixture.array.items) |programFixture| {
        const definition = programFixture.object.get("program").?.object;
        testHelpWidth = switch (programFixture.object.get("helpWidth").?) {
            .integer => |width| @intCast(width),
            else => null,
        };
        testColors = helpers.boolField(programFixture, "colors");
        for (programFixture.object.get("cases").?.array.items) |testCase| {
            const argv = try helpers.stringArray(allocator, testCase.object.get("argv").?);
            errdefer std.debug.print("program: {s}\nargv: {f}\n", .{ helpers.stringField(programFixture, "title"), std.json.fmt(argv, .{}) });

            var recorder = createRecorder(allocator);
            const program = Command.init(allocator, helpers.stringField(programFixture.object.get("program").?, "name"));
            _ = program.configureOutput(recorder.output());
            try buildCommand(allocator, program, definition, &recorder);

            const outcome = program.parse(argv);
            const result = try describeResult(allocator, program, outcome);
            try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(allocator, testCase.object.get("result").?, .{}), result);
            try std.testing.expectEqualStrings(helpers.stringField(testCase, "stdout"), recorder.stdout.written());
            try std.testing.expectEqualStrings(helpers.stringField(testCase, "stderr"), recorder.stderr.written());
            const expectedEvents = testCase.object.get("events").?.array.items;
            try std.testing.expectEqual(expectedEvents.len, recorder.events.items.len);
            for (expectedEvents, recorder.events.items) |expectedEvent, recordedEvent| {
                try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(allocator, expectedEvent, .{}), recordedEvent);
            }
            caseCount += 1;
        }
    }
    try std.testing.expect(caseCount > 100);
}

test "splitOptionFlags finds short and long flags in every supported layout" {
    const shortAndLong = commander.splitOptionFlags("-k, --key <keyfile>");
    try std.testing.expectEqualStrings("-k", shortAndLong.shortFlag.?);
    try std.testing.expectEqualStrings("--key", shortAndLong.longFlag.?);

    const twoLongs = commander.splitOptionFlags("--dk, --dest-key <keyfile>");
    try std.testing.expectEqualStrings("--dk", twoLongs.shortFlag.?);
    try std.testing.expectEqualStrings("--dest-key", twoLongs.longFlag.?);

    const longThenShort = commander.splitOptionFlags("--verbose|-v");
    try std.testing.expectEqualStrings("-v", longThenShort.shortFlag.?);
    try std.testing.expectEqualStrings("--verbose", longThenShort.longFlag.?);

    const shortOnly = commander.splitOptionFlags("-o [value]");
    try std.testing.expectEqualStrings("-o", shortOnly.shortFlag.?);
    try std.testing.expect(shortOnly.longFlag == null);

    const longOnly = commander.splitOptionFlags("--tools");
    try std.testing.expect(longOnly.shortFlag == null);
    try std.testing.expectEqualStrings("--tools", longOnly.longFlag.?);

    const many = commander.splitOptionFlags("-a -b -c -d -e -f -g -h -i --j");
    try std.testing.expectEqualStrings("-a", many.shortFlag.?);
    try std.testing.expect(many.longFlag == null);
}

test "Option parses its flags" {
    const key = Option.init("-k, --key <keyfile>", "The key.");
    try std.testing.expect(key.required);
    try std.testing.expect(!key.optional);
    try std.testing.expect(!key.negate);
    try std.testing.expect(!key.mandatory);
    try std.testing.expect(!key.isBoolean());
    try std.testing.expectEqualStrings("key", key.name());
    try std.testing.expectEqualStrings("The key.", key.description);

    const optional = Option.init("-o [value]", "");
    try std.testing.expect(optional.optional);
    try std.testing.expect(!optional.isBoolean());
    try std.testing.expectEqualStrings("o", optional.name());

    const negated = Option.init("--no-browser", "");
    try std.testing.expect(negated.negate);
    try std.testing.expect(!negated.isBoolean());

    const flag = Option.init("--tools", "");
    try std.testing.expect(flag.isBoolean());
    try std.testing.expect(flag.defaultValue == null);
    try std.testing.expect(flag.parseArg == null);
}

test "Option.is and attributeName" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const destKey = Option.init("--dk, --dest-key <keyfile>", "");
    try std.testing.expect(destKey.is("--dk"));
    try std.testing.expect(destKey.is("--dest-key"));
    try std.testing.expect(!destKey.is("--dest"));
    try std.testing.expectEqualStrings("destKey", try destKey.attributeName(allocator));
    try std.testing.expectEqualStrings("generateKey", try Option.init("-g, --generate-key", "").attributeName(allocator));
    try std.testing.expectEqualStrings("browser", try Option.init("--no-browser", "").attributeName(allocator));
    try std.testing.expectEqualStrings("q", try Option.init("-q", "").attributeName(allocator));
    try std.testing.expect(!Option.init("-q", "").is("--q"));
}

test "camelcase joins dashed words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("pageSize", try commander.camelcase(allocator, "page-size"));
    try std.testing.expectEqualStrings("s3Cred", try commander.camelcase(allocator, "s3-cred"));
    try std.testing.expectEqualStrings("plain", try commander.camelcase(allocator, "plain"));
}

test "Argument parses required, optional and variadic declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const files = Argument.init("<files...>", "The files.");
    try std.testing.expect(files.required);
    try std.testing.expect(files.variadic);
    try std.testing.expectEqualStrings("files", files.name());
    try std.testing.expectEqualStrings("<files...>", try commander.humanReadableArgName(allocator, files));

    const command = Argument.init("[command]", "");
    try std.testing.expect(!command.required);
    try std.testing.expect(!command.variadic);
    try std.testing.expectEqualStrings("[command]", try commander.humanReadableArgName(allocator, command));

    const optionalList = Argument.init("[rest...]", "");
    try std.testing.expectEqualStrings("[rest...]", try commander.humanReadableArgName(allocator, optionalList));

    const bare = Argument.init("file", "");
    try std.testing.expect(bare.required);
    try std.testing.expectEqualStrings("file", bare.name());

    // "..." alone is a name, not a variadic marker.
    const dots = Argument.init("<...>", "");
    try std.testing.expect(!dots.variadic);
    try std.testing.expectEqualStrings("...", dots.name());
}

test "editDistance counts transpositions as one edit and counts UTF-16 units" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqual(@as(usize, 0), try commander.editDistance(allocator, "full", "full"));
    try std.testing.expectEqual(@as(usize, 1), try commander.editDistance(allocator, "flul", "full"));
    try std.testing.expectEqual(@as(usize, 1), try commander.editDistance(allocator, "ful", "full"));
    try std.testing.expectEqual(@as(usize, 3), try commander.editDistance(allocator, "abc", "xyz"));
    try std.testing.expectEqual(@as(usize, 10), try commander.editDistance(allocator, "a", "abcdefghij"));
    try std.testing.expectEqual(@as(usize, 1), try commander.editDistance(allocator, "f\u{fc}ll", "full"));
    try std.testing.expectEqual(@as(usize, 2), try commander.editDistance(allocator, "\u{1F4F7}", "ab"));
}

test "suggestSimilar suggests the closest candidates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("\n(Did you mean --full?)", try commander.suggestSimilar(allocator, "--flul", &.{ "--full", "--force", "--help" }));
    try std.testing.expectEqualStrings("\n(Did you mean one of --dest, --test?)", try commander.suggestSimilar(allocator, "--fest", &.{ "--test", "--dest", "--dest" }));
    try std.testing.expectEqualStrings("", try commander.suggestSimilar(allocator, "--zzzzzz", &.{ "--full", "--force" }));
    try std.testing.expectEqualStrings("", try commander.suggestSimilar(allocator, "--x", &.{}));
    try std.testing.expectEqualStrings("\n(Did you mean replicate?)", try commander.suggestSimilar(allocator, "replicat", &.{ "replicate", "rep", "a" }));
    try std.testing.expectEqualStrings("", try commander.suggestSimilar(allocator, "--a", &.{ "--b", "-c" }));
}

test "displayWidth, jsLength and stripColor measure like JavaScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqual(@as(usize, 4), commander.displayWidth("\x1b[1mBold\x1b[22m"));
    try std.testing.expectEqual(@as(usize, 4), commander.displayWidth("\x1b[1;31mBold"));
    try std.testing.expectEqual(@as(usize, 4), commander.displayWidth("\x1b[xy"));
    try std.testing.expectEqual(@as(usize, 1), commander.displayWidth("\x1b"));
    try std.testing.expectEqual(@as(usize, 3), commander.jsLength("a\u{2192}b"));
    try std.testing.expectEqual(@as(usize, 2), commander.jsLength("\u{1F4F7}"));
    try std.testing.expectEqual(@as(usize, 2), commander.jsLength("\xff\xc3"));
    try std.testing.expectEqualStrings("Bold text", try commander.stripColor(allocator, "\x1b[1mBold\x1b[22m text"));
    try std.testing.expectEqualStrings("plain", try commander.stripColor(allocator, "plain"));
    try std.testing.expectEqualStrings("\x1b[x", try commander.stripColor(allocator, "\x1b[x"));
}

test "isJsWhitespace matches JavaScript's \\s" {
    try std.testing.expect(commander.isJsWhitespace(' '));
    try std.testing.expect(commander.isJsWhitespace('\t'));
    try std.testing.expect(commander.isJsWhitespace(0xA0));
    try std.testing.expect(commander.isJsWhitespace(0x2005));
    try std.testing.expect(commander.isJsWhitespace(0x3000));
    try std.testing.expect(!commander.isJsWhitespace('a'));
    try std.testing.expect(!commander.isJsWhitespace(0x200B));
}

test "stringifyOptionValue writes JSON like JSON.stringify" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("false", try commander.stringifyOptionValue(allocator, .{ .boolean = false }));
    try std.testing.expectEqualStrings("true", try commander.stringifyOptionValue(allocator, .{ .boolean = true }));
    try std.testing.expectEqualStrings("\"say \\\"hi\\\"\"", try commander.stringifyOptionValue(allocator, .{ .string = "say \"hi\"" }));
}

test "useColor follows NO_COLOR, FORCE_COLOR and CLICOLOR_FORCE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect(commander.useColor(null) == null);

    var empty = std.process.Environ.Map.init(allocator);
    try std.testing.expect(commander.useColor(&empty) == null);

    var noColor = std.process.Environ.Map.init(allocator);
    try noColor.put("NO_COLOR", "1");
    try std.testing.expectEqual(@as(?bool, false), commander.useColor(&noColor));

    var emptyNoColor = std.process.Environ.Map.init(allocator);
    try emptyNoColor.put("NO_COLOR", "");
    try std.testing.expect(commander.useColor(&emptyNoColor) == null);

    var forceOff = std.process.Environ.Map.init(allocator);
    try forceOff.put("FORCE_COLOR", "0");
    try std.testing.expectEqual(@as(?bool, false), commander.useColor(&forceOff));

    var forceFalse = std.process.Environ.Map.init(allocator);
    try forceFalse.put("FORCE_COLOR", "false");
    try std.testing.expectEqual(@as(?bool, false), commander.useColor(&forceFalse));

    var forceOn = std.process.Environ.Map.init(allocator);
    try forceOn.put("FORCE_COLOR", "1");
    try std.testing.expectEqual(@as(?bool, true), commander.useColor(&forceOn));

    var forceEmpty = std.process.Environ.Map.init(allocator);
    try forceEmpty.put("FORCE_COLOR", "");
    try std.testing.expect(commander.useColor(&forceEmpty) == null);

    var cliColorForce = std.process.Environ.Map.init(allocator);
    try cliColorForce.put("CLICOLOR_FORCE", "");
    try std.testing.expectEqual(@as(?bool, true), commander.useColor(&cliColorForce));
}

test "the getters return what the builders set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const program = Command.init(allocator, "");
    try std.testing.expectEqualStrings("", program.getName());
    try std.testing.expect(program.getAlias() == null);
    const list = program
        .command("list", .{})
        .aliases(&.{ "ls", "l" })
        .description("Lists things.");
    try std.testing.expectEqualStrings("list", list.getName());
    try std.testing.expectEqualStrings("ls", list.getAlias().?);
    try std.testing.expectEqual(@as(usize, 2), list.getAliases().len);
    try std.testing.expectEqualStrings("l", list.getAliases()[1]);
    try std.testing.expectEqualStrings("Lists things.", list.getDescription());
    try std.testing.expect(program.findCommand("l") == list);
    try std.testing.expect(program.findCommand("x") == null);
    _ = program.name("tool");
    try std.testing.expectEqualStrings("tool", program.getName());

    // A parse gives the program its default name when it has none.
    const unnamed = Command.init(allocator, "");
    try unnamed.parse(&.{});
    try std.testing.expectEqualStrings("program", unnamed.getName());
}

test "option values can be set and read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const program = Command.init(allocator, "tool")
        .option("--db <path>", "The database.", .{ .string = "x" })
        .option("--no-color", "No color.", null);
    try std.testing.expectEqualStrings("x", program.getOptionValue("db").?.string);
    try std.testing.expect(program.getOptionValue("color").?.boolean);
    try program.setOptionValue("db", .{ .string = "y" });
    try std.testing.expectEqualStrings("y", program.opts().get("db").?.string);
    try std.testing.expect(program.getOptionValue("other") == null);
    try std.testing.expect(program.findOption("--db") != null);
    try std.testing.expect(program.findOption("--nope") == null);
}

test "parseOptions separates operands and unknown arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const program = Command.init(allocator, "tool")
        .option("--db <path>", "", null)
        .option("-y, --yes", "", null);
    const parsed = try program.parseOptions(&.{ "first", "--db", "x", "--unknown", "after", "-y", "--", "last" });
    try std.testing.expectEqual(@as(usize, 1), parsed.operands.len);
    try std.testing.expectEqualStrings("first", parsed.operands[0]);
    try std.testing.expectEqual(@as(usize, 4), parsed.unknown.len);
    try std.testing.expectEqualStrings("--unknown", parsed.unknown[0]);
    try std.testing.expectEqualStrings("after", parsed.unknown[1]);
    try std.testing.expectEqualStrings("--", parsed.unknown[2]);
    try std.testing.expectEqualStrings("last", parsed.unknown[3]);
    try std.testing.expectEqualStrings("x", program.getOptionValue("db").?.string);
    try std.testing.expect(program.getOptionValue("yes").?.boolean);
}

test "an option without a parser, value or flag kind is set to the empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const program = Command.init(allocator, "tool");
    const context: u8 = 0;
    _ = program.optionWithArgParser("--value <text>", "", &context, undefinedParser);
    _ = try program.parseOptions(&.{ "--value", "x" });
    try std.testing.expectEqualStrings("", program.getOptionValue("value").?.string);
}

//
// An option parser that returns `undefined`.
//
fn undefinedParser(context: *const u8, value: ?[]const u8, previous: ?OptionValue) !?OptionValue {
    _ = context;
    _ = value;
    _ = previous;
    return null;
}

test "error writes the message and exits with the given code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var recorder = createRecorder(allocator);
    const program = Command.init(allocator, "tool").configureOutput(recorder.output());
    const subcommand = program.command("sub", .{});
    try std.testing.expectEqual(error.Exit, subcommand.@"error"("error: custom", .{}));
    try std.testing.expectEqualStrings("error: custom\n", recorder.stderr.written());
    const details = program.getCommanderError().?;
    try std.testing.expectEqual(@as(u8, 1), details.exitCode);
    try std.testing.expectEqualStrings("commander.error", details.code);
    try std.testing.expectEqualStrings("error: custom", details.message);

    _ = program.exitOverride();
    try std.testing.expectEqual(error.CommanderError, program.@"error"("error: other", .{
        .exitCode = 3,
        .code = "custom.code",
    }));
    try std.testing.expectEqual(@as(u8, 3), subcommand.getCommanderError().?.exitCode);
    try std.testing.expectEqualStrings("custom.code", subcommand.getCommanderError().?.code);
}

test "copyInheritedSettings shares the output and copies the exit and help settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = Command.init(allocator, "source").exitOverride().helpOption(false);
    const target = Command.init(allocator, "target").copyInheritedSettings(source);
    try std.testing.expect(target.exitOverridden);
    try std.testing.expect(!target.helpOptionEnabled);
    try std.testing.expect(target.outputConfiguration == source.outputConfiguration);
    try std.testing.expect(target.getHelpOption() == null);
    try std.testing.expect(source.getHelpCommand() == null);
}

test "helpInformation and outputHelp render the help of a command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    testHelpWidth = null;
    testColors = false;
    var recorder = createRecorder(allocator);
    const program = Command.init(allocator, "tool").configureOutput(recorder.output());
    const sub = program
        .command("sub <input> [rest...]", .{})
        .alias("s")
        .description("Does the \x1b[1msub\x1b[22m thing.")
        .option("-f, --force", "Force it.", null)
        .addHelpText(.before, "Before.");
    const expected =
        \\Usage: tool sub|s [options] <input> [rest...]
        \\
        \\Does the sub thing.
        \\
        \\Options:
        \\  -f, --force  Force it.
        \\  -h, --help   display help for command
        \\
    ;
    try std.testing.expectEqualStrings(expected, try sub.helpInformation(false));
    try sub.outputHelp(true);
    try std.testing.expectEqualStrings("Before.\n" ++ expected, recorder.stderr.written());
    try std.testing.expectEqualStrings("", recorder.stdout.written());

    // Without options, subcommands, arguments or a help option the usage is empty.
    const bare = Command.init(allocator, "bare").helpOption(false);
    try std.testing.expectEqualStrings("", try bare.usage(allocator));
    const helper = Help{};
    try std.testing.expectEqualStrings("bare ", try helper.commandUsage(allocator, bare));
}
