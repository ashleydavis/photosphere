//
// Port of the parts of the third-party `commander` package (v13.1.0) that the psi CLI (apps/cli/index.ts and
// apps/cli/src) uses. This file has no TypeScript counterpart in the repo: it stands in for lib/command.js,
// lib/help.js, lib/option.js, lib/argument.js, lib/error.js and lib/suggestSimilar.js, and keeps their parsing
// rules, error messages, exit codes and help layout.
//
// A command line is built by chaining calls onto a `Command`, like in index.ts. The builder methods panic when
// out of memory instead of returning an error, so that a definition stays one chain of calls: the command tree
// is built once at startup and nothing else could run without that memory.
//
// Commander actions, hooks and option parsers are closures. A Zig function captures nothing, so each takes a
// context pointer handed over alongside the function, which is the same information arriving by another route.
//
// Commander throws a `CommanderError` (with `.exitOverride()`) or calls `process.exit` (without). Here that is
// `error.CommanderError` or `error.Exit`, and the details (exit code, code and message) are kept on the root
// command (`getCommanderError`).
//
// Not ported (psi does not use them): `.version()`, `.summary()`, `.usage(str)`, `.helpOption(flags)`,
// `.configureHelp()`, `.showHelpAfterError()`, `.showSuggestionAfterError()`, `.allowUnknownOption()`,
// `.allowExcessArguments()`, `.enablePositionalOptions()`, `.passThroughOptions()`,
// `.storeOptionsAsProperties()`, `.combineFlagAndOptionalValue()`, `.executableDir()`, executable and default
// subcommands, the `preSubcommand` and `postAction` hooks, variadic options, option choices, presets,
// environment variables, implied and conflicting options, hidden options, argument defaults and parsers,
// `addHelpText` with a function, `.optsWithGlobals()`, parse state save/restore, the legacy `command:*` events,
// and the checks that throw for a program defined wrongly (psi's definitions are valid).
//

const std = @import("std");
const builtin = @import("builtin");
const node_utils = @import("node-utils-zig");
const storage_zig = @import("storage-zig");
const tty = @import("tty.zig");

//
// Sorts suggestions. Commander uses `localeCompare`; this is the numeric flavour, which only differs for names
// with runs of digits of different values.
//
const localeLessThan = storage_zig.locale_compare.lessThan;

//
// The details of an error that stopped a parse (commander `CommanderError`).
//
pub const CommanderError = struct {
    // The process exit code that goes with the error.
    exitCode: u8,

    // The commander error code (e.g. "commander.unknownOption").
    code: []const u8,

    // The error message (e.g. "error: unknown option '--x'").
    message: []const u8,
};

//
// The value of an option: a boolean flag or text.
//
pub const OptionValue = union(enum) {
    // The value of a boolean or negated option (or an option with an optional value that was not given).
    boolean: bool,

    // The value of an option that takes a value.
    string: []const u8,
};

//
// The option values of a command, by attribute name, in the order they were first set (commander `opts()`).
//
pub const OptionValues = std.StringArrayHashMapUnmanaged(OptionValue);

//
// The value of a declared argument passed to an action (commander `processedArgs`).
//
pub const ArgumentValue = union(enum) {
    // An optional argument that was not given (`undefined`).
    none,

    // The value of an argument.
    string: []const u8,

    // The values of a variadic argument.
    list: []const []const u8,
};

//
// An option parser: called with the text of the option (null for a boolean flag, where commander passes
// `undefined`) and the previous value; returns the new value, or null for `undefined`.
//
const IParseArg = struct {
    // The context handed to `.optionWithArgParser` alongside the function.
    context: *const anyopaque,

    // Calls the parser with its context.
    function: *const fn (context: *const anyopaque, value: ?[]const u8, previous: ?OptionValue) anyerror!?OptionValue,
};

//
// An option declaration (commander `Option`).
//
pub const Option = struct {
    // The flags as declared, e.g. "-k, --key <keyfile>".
    flags: []const u8,

    // The help text.
    description: []const u8,

    // True when a value must be supplied when the option is specified (`<value>`).
    required: bool,

    // True when a value is optional when the option is specified (`[value]`).
    optional: bool,

    // True when the option must have a value after parsing (`.requiredOption`).
    mandatory: bool,

    // The short flag ("-k"), or the first of two long flags ("--dk"), or null.
    short: ?[]const u8,

    // The long flag ("--key"), or null.
    long: ?[]const u8,

    // True for a `--no-` option.
    negate: bool,

    // The default value, or null when there is none (`undefined`).
    defaultValue: ?OptionValue,

    // The custom processing function, or null.
    parseArg: ?IParseArg,

    //
    // Parses the flags of an option declaration (the Option constructor).
    //
    pub fn init(flags: []const u8, description: []const u8) Option {
        const optionFlags = splitOptionFlags(flags);
        var negate = false;
        if (optionFlags.longFlag) |longFlag| {
            negate = std.mem.startsWith(u8, longFlag, "--no-");
        }
        return .{
            .flags = flags,
            .description = description,
            .required = std.mem.indexOfScalar(u8, flags, '<') != null,
            .optional = std.mem.indexOfScalar(u8, flags, '[') != null,
            .mandatory = false,
            .short = optionFlags.shortFlag,
            .long = optionFlags.longFlag,
            .negate = negate,
            .defaultValue = null,
            .parseArg = null,
        };
    }

    //
    // Return option name: the long flag without "--", else the short flag without "-".
    //
    pub fn name(self: Option) []const u8 {
        if (self.long) |longFlag| {
            return longFlag[2..];
        }
        return self.short.?[1..];
    }

    //
    // Return option name, in a camelcase format that can be used as an object attribute key
    // ("dest-key" -> "destKey"; "no-browser" -> "browser").
    //
    pub fn attributeName(self: Option, allocator: std.mem.Allocator) ![]const u8 {
        var optionName = self.name();
        if (self.negate and std.mem.startsWith(u8, optionName, "no-")) {
            optionName = optionName[3..];
        }
        return camelcase(allocator, optionName);
    }

    //
    // Check if `arg` matches the short or long flag.
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
    // Return whether a boolean option. Options are one of boolean, negated, required argument, or optional
    // argument.
    //
    pub fn isBoolean(self: Option) bool {
        return !self.required and !self.optional and !self.negate;
    }
};

//
// Converts "dest-key" to "destKey" (commander `camelcase`).
//
pub fn camelcase(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var upperNext = false;
    for (text) |character| {
        if (character == '-') {
            upperNext = true;
            continue;
        }
        if (upperNext) {
            try result.append(allocator, std.ascii.toUpper(character));
        }
        else {
            try result.append(allocator, character);
        }
        upperNext = false;
    }
    return result.items;
}

//
// The short and long flags of an option.
//
pub const IOptionFlags = struct {
    // The short flag (or the first of two long flags), or null.
    shortFlag: ?[]const u8,

    // The long flag, or null.
    longFlag: ?[]const u8,
};

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
// Split the short and long flag out of something like '-m,--mixed <value>' (commander `splitOptionFlags`).
//
pub fn splitOptionFlags(flags: []const u8) IOptionFlags {
    var parts: [8][]const u8 = undefined;
    var count: usize = 0;
    var iterator = std.mem.tokenizeAny(u8, flags, " |,");
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
        .shortFlag = shortFlag,
        .longFlag = longFlag,
    };
}

//
// A declared command argument (commander `Argument`).
//
pub const Argument = struct {
    // The help text.
    description: []const u8,

    // True when the argument collects the remaining arguments (`<files...>`).
    variadic: bool,

    // True when the argument must be given (`<name>`).
    required: bool,

    // The name without the brackets and the dots.
    argumentName: []const u8,

    //
    // Parses an argument declaration like "<file>", "[file]" or "<files...>" (the Argument constructor).
    //
    pub fn init(declaration: []const u8, description: []const u8) Argument {
        var required = true;
        var argumentName = declaration;
        if (declaration.len > 0 and (declaration[0] == '<' or declaration[0] == '[')) {
            required = declaration[0] == '<';
            argumentName = declaration[1 .. declaration.len - 1];
        }
        var variadic = false;
        if (argumentName.len > 3 and std.mem.endsWith(u8, argumentName, "...")) {
            variadic = true;
            argumentName = argumentName[0 .. argumentName.len - 3];
        }
        return .{
            .description = description,
            .variadic = variadic,
            .required = required,
            .argumentName = argumentName,
        };
    }

    //
    // Return argument name.
    //
    pub fn name(self: Argument) []const u8 {
        return self.argumentName;
    }
};

//
// Takes an argument and returns its human readable equivalent for help usage ("<files...>", "[command]").
//
pub fn humanReadableArgName(allocator: std.mem.Allocator, argument: Argument) ![]const u8 {
    const dots = if (argument.variadic) "..." else "";
    if (argument.required) {
        return std.fmt.allocPrint(allocator, "<{s}{s}>", .{ argument.name(), dots });
    }
    return std.fmt.allocPrint(allocator, "[{s}{s}]", .{ argument.name(), dots });
}

//
// The life cycle events a hook can be added for.
// Not ported: preSubcommand and postAction (psi does not use them).
//
pub const HookEvent = enum {
    // Called before the action handler of a command (or of any of its subcommands).
    preAction,
};

//
// A hook: called with the command the hook was added to and the command whose action runs.
//
const IHook = struct {
    // The event the hook is for.
    event: HookEvent,

    // The context handed to `.hook` alongside the function.
    context: *const anyopaque,

    // Calls the hook with its context.
    function: *const fn (context: *const anyopaque, thisCommand: *Command, actionCommand: *Command) anyerror!void,
};

//
// An action handler: called with the processed arguments, the option values and the command.
//
const IAction = struct {
    // The context handed to `.action` alongside the function.
    context: *const anyopaque,

    // Calls the action with its context.
    function: *const fn (context: *const anyopaque, args: []const ArgumentValue, options: *const OptionValues, command: *Command) anyerror!void,
};

//
// Where `addHelpText` puts its text.
//
pub const HelpTextPosition = enum {
    // Before the help of this command and of its subcommands (written by the command itself for its own help and
    // for the help of every descendant).
    beforeAll,

    // Before the help of this command.
    before,

    // After the help of this command.
    after,

    // After the help of this command and of its subcommands.
    afterAll,
};

//
// Text added around the help (`addHelpText`).
//
const IHelpText = struct {
    // Where the text goes.
    position: HelpTextPosition,

    // The text (nothing is written when it is empty).
    text: []const u8,
};

//
// Options of `.command()` (commander `ICommandOptions`).
//
pub const ICommandOptions = struct {
    // Hides the command from the help.
    hidden: bool = false,
};

//
// The options of `.error()`.
//
pub const IErrorOptions = struct {
    // The exit code.
    exitCode: u8 = 1,

    // The commander error code.
    code: []const u8 = "commander.error",
};

//
// Where commander writes and what it knows about the destination (commander `configureOutput`). The
// defaults stand in for `process.stdout` and `process.stderr`.
//
pub const IOutputConfiguration = struct {
    // Where normal output (help) goes, or null for the process's stdout.
    writeOut: ?*std.Io.Writer = null,

    // Where errors go, or null for the process's stderr.
    writeErr: ?*std.Io.Writer = null,

    // The width help is wrapped to when written to stdout, or null for 80.
    getOutHelpWidth: *const fn () ?usize = defaultOutHelpWidth,

    // The width help is wrapped to when written to stderr, or null for 80.
    getErrHelpWidth: *const fn () ?usize = defaultErrHelpWidth,

    // True when stdout shows colors (otherwise color is stripped from the help).
    getOutHasColors: *const fn () bool = defaultOutHasColors,

    // True when stderr shows colors (otherwise color is stripped from the help).
    getErrHasColors: *const fn () bool = defaultErrHasColors,
};

//
// `process.stdout.isTTY ? process.stdout.columns : undefined`.
//
fn defaultOutHelpWidth() ?usize {
    return tty.columns(tty.stdout_fd);
}

//
// `process.stderr.isTTY ? process.stderr.columns : undefined`.
//
fn defaultErrHelpWidth() ?usize {
    return tty.columns(tty.stderr_fd);
}

//
// `useColor() ?? (process.stdout.isTTY && process.stdout.hasColors?.())`.
//
fn defaultOutHasColors() bool {
    return useColor(node_utils.process_env.getEnvironMap()) orelse (tty.isatty(tty.stdout_fd) and tty.hasColors(16, node_utils.process_env.getEnvironMap()));
}

//
// `useColor() ?? (process.stderr.isTTY && process.stderr.hasColors?.())`.
//
fn defaultErrHasColors() bool {
    return useColor(node_utils.process_env.getEnvironMap()) orelse (tty.isatty(tty.stderr_fd) and tty.hasColors(16, node_utils.process_env.getEnvironMap()));
}

//
// Gets an environment variable from a map that may be missing.
//
fn environmentValue(environment: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const map = environment orelse return null;
    return map.get(key);
}

//
// Test for common conventions (NO_COLOR, FORCE_COLOR, CLICOLOR_FORCE): false or true when they decide, null
// (`undefined`) when they do not.
//
pub fn useColor(environment: ?*const std.process.Environ.Map) ?bool {
    const noColor = environmentValue(environment, "NO_COLOR");
    const forceColor = environmentValue(environment, "FORCE_COLOR");
    if ((noColor != null and noColor.?.len > 0) or
        (forceColor != null and (std.mem.eql(u8, forceColor.?, "0") or std.mem.eql(u8, forceColor.?, "false"))))
    {
        return false;
    }
    if ((forceColor != null and forceColor.?.len > 0) or environmentValue(environment, "CLICOLOR_FORCE") != null) {
        return true;
    }
    return null;
}

//
// Writes text to a process stream (`process.stdout.write` / `process.stderr.write`), ignoring write errors.
//
fn writeToProcessStream(file: std.Io.File, text: []const u8) void {
    var buffer: [1024]u8 = undefined;
    var fileWriter = file.writerStreaming(std.Options.debug_io, &buffer);
    fileWriter.interface.writeAll(text) catch {};
    fileWriter.interface.flush() catch {};
}

//
// Writes text to a configured writer, or to the process stream when there is none.
//
fn writeTo(writer: ?*std.Io.Writer, file: std.Io.File, text: []const u8) void {
    if (writer) |destination| {
        destination.writeAll(text) catch {};
        destination.flush() catch {};
        return;
    }
    writeToProcessStream(file, text);
}

//
// Where help is written, and how (commander `_getOutputContext`).
//
const IOutputContext = struct {
    // True when the help goes to stderr.
    isError: bool,

    // True when the destination shows colors.
    hasColors: bool,

    // The help width of the destination, or null.
    helpWidth: ?usize,

    // The command whose output configuration is used.
    command: *Command,

    //
    // Writes text to the destination, stripping color when it does not show colors.
    //
    fn write(self: IOutputContext, allocator: std.mem.Allocator, text: []const u8) !void {
        var output = text;
        if (!self.hasColors) {
            output = try stripColor(allocator, output);
        }
        if (self.isError) {
            writeTo(self.command.outputConfiguration.writeErr, std.Io.File.stderr(), output);
        }
        else {
            writeTo(self.command.outputConfiguration.writeOut, std.Io.File.stdout(), output);
        }
    }
};

//
// The result of `parseOptions`.
//
pub const IParseOptionsResult = struct {
    // Operands: the arguments that are not options or option values.
    operands: []const []const u8,

    // The first unknown option and every argument after it.
    unknown: []const []const u8,
};

//
// What an option listener receives: nothing (`undefined`, a boolean flag), null (an optional value that was
// not given) or the text.
//
const OptionEvent = union(enum) {
    // `emit('option:name')`: a boolean or negated flag.
    none,

    // `emit('option:name', null)`: an option with an optional value, used without one.
    missing,

    // `emit('option:name', value)`: the value of the option.
    text: []const u8,
};

//
// Casts a context pointer back to the type it was registered with.
//
fn castContext(comptime Context: type, erased: *const anyopaque) Context {
    return @ptrCast(@alignCast(@constCast(erased)));
}

//
// A command (commander `Command`).
//
pub const Command = struct {
    // Allocates everything the command holds.
    allocator: std.mem.Allocator,

    // The subcommands.
    commands: std.ArrayList(*Command) = .empty,

    // The options.
    options: std.ArrayList(Option) = .empty,

    // The command this was added to, or null for the program.
    parent: ?*Command = null,

    // The declared arguments.
    registeredArguments: std.ArrayList(Argument) = .empty,

    // The command line arguments with the options removed.
    args: []const []const u8 = &.{},

    // Like `args` but after collecting variadic arguments.
    processedArgs: []const ArgumentValue = &.{},

    // The command name (`_name`).
    commandName: []const u8,

    // The option values (`_optionValues`).
    optionValues: OptionValues = .empty,

    // The action handler, or null.
    actionHandler: ?IAction = null,

    // True when errors throw a CommanderError instead of exiting the process (`_exitCallback`).
    exitOverridden: bool = false,

    // The aliases (`_aliases`).
    aliasList: std.ArrayList([]const u8) = .empty,

    // The description (`_description`).
    descriptionText: []const u8 = "",

    // The life cycle hooks (`_lifeCycleHooks`).
    lifeCycleHooks: std.ArrayList(IHook) = .empty,

    // Where output goes, shared with the subcommands made by `.command()` (`_outputConfiguration`).
    outputConfiguration: *IOutputConfiguration,

    // True when the command is hidden from the help (`_hidden`).
    hidden: bool = false,

    // False when the built-in help option is disabled (`_helpOption === null`).
    helpOptionEnabled: bool = true,

    // Whether to add the implicit help command, or null when not decided (`_addImplicitHelpCommand`).
    addImplicitHelpCommand: ?bool = null,

    // The help command, created on demand and inherited by `.command()` (`_helpCommand`).
    helpCommandValue: ?*Command = null,

    // The text added around the help (the `*Help` listeners).
    helpTexts: std.ArrayList(IHelpText) = .empty,

    // The error that stopped the last parse (kept on the root command).
    commanderError: ?CommanderError = null,

    //
    // Creates a command (`new Command(name)`).
    //
    pub fn init(allocator: std.mem.Allocator, commandName: []const u8) *Command {
        const created = allocator.create(Command) catch @panic("out of memory building the command line");
        const outputConfiguration = allocator.create(IOutputConfiguration) catch @panic("out of memory building the command line");
        outputConfiguration.* = .{};
        created.* = .{
            .allocator = allocator,
            .commandName = commandName,
            .outputConfiguration = outputConfiguration,
        };
        return created;
    }

    //
    // Copy settings that are useful to have in common across root command and subcommands.
    // (Used internally when adding a command using `.command()` so subcommands inherit parent settings.)
    //
    pub fn copyInheritedSettings(self: *Command, sourceCommand: *const Command) *Command {
        self.outputConfiguration = sourceCommand.outputConfiguration;
        self.helpOptionEnabled = sourceCommand.helpOptionEnabled;
        self.helpCommandValue = sourceCommand.helpCommandValue;
        self.exitOverridden = sourceCommand.exitOverridden;
        return self;
    }

    //
    // The command and its ancestors, starting with the command (`_getCommandAndAncestors`).
    //
    fn getCommandAndAncestors(self: *Command) ![]*Command {
        var result: std.ArrayList(*Command) = .empty;
        var current: ?*Command = self;
        while (current) |ancestorCommand| {
            try result.append(self.allocator, ancestorCommand);
            current = ancestorCommand.parent;
        }
        return result.items;
    }

    //
    // The root command, where the error of a parse is kept.
    //
    fn root(self: *Command) *Command {
        var current = self;
        while (current.parent) |parentCommand| {
            current = parentCommand;
        }
        return current;
    }

    //
    // The error that stopped the last parse, or null.
    //
    pub fn getCommanderError(self: *Command) ?CommanderError {
        return self.root().commanderError;
    }

    //
    // Define a command, e.g. `.command("hash-file <file>")`, and return the new command so it can be chained.
    //
    pub fn command(self: *Command, nameAndArgs: []const u8, commandOptions: ICommandOptions) *Command {
        const trimmed = std.mem.trimStart(u8, nameAndArgs, " ");
        const nameEnd = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
        const commandName = trimmed[0..nameEnd];
        const commandArgs = std.mem.trimStart(u8, trimmed[nameEnd..], " ");

        const created = Command.init(self.allocator, commandName);
        created.hidden = commandOptions.hidden;
        if (commandArgs.len > 0) {
            _ = created.arguments(commandArgs);
        }
        self.registerCommand(created);
        created.parent = self;
        _ = created.copyInheritedSettings(self);
        return created;
    }

    //
    // Add a prepared subcommand (made with `Command.init`). Unlike `.command()`, it does not inherit settings.
    //
    pub fn addCommand(self: *Command, subcommand: *Command) *Command {
        self.registerCommand(subcommand);
        subcommand.parent = self;
        return self;
    }

    //
    // Register a command (`_registerCommand`).
    //
    fn registerCommand(self: *Command, subcommand: *Command) void {
        self.commands.append(self.allocator, subcommand) catch @panic("out of memory building the command line");
    }

    //
    // Define argument syntax for command, e.g. `.argument("<files...>", "The media files.")`.
    //
    pub fn argument(self: *Command, declaration: []const u8, argumentDescription: []const u8) *Command {
        return self.addArgument(Argument.init(declaration, argumentDescription));
    }

    //
    // Define argument syntax for command, adding multiple at once (without descriptions),
    // e.g. `.arguments("<path> <hash> <length>")`.
    //
    pub fn arguments(self: *Command, names: []const u8) *Command {
        var iterator = std.mem.tokenizeScalar(u8, std.mem.trim(u8, names, " \t\r\n"), ' ');
        while (iterator.next()) |detail| {
            _ = self.argument(detail, "");
        }
        return self;
    }

    //
    // Define argument syntax for command, adding a prepared argument.
    //
    pub fn addArgument(self: *Command, declared: Argument) *Command {
        self.registeredArguments.append(self.allocator, declared) catch @panic("out of memory building the command line");
        return self;
    }

    //
    // Customise or override default help command. By default a help command is automatically added if your
    // command has subcommands; `.addHelpCommand(false)` turns it off.
    //
    pub fn addHelpCommand(self: *Command, enable: bool) *Command {
        self.addImplicitHelpCommand = enable;
        return self;
    }

    //
    // Creates the default help command ("help [command]").
    //
    fn createDefaultHelpCommand(self: *Command) *Command {
        const helpCommand = Command.init(self.allocator, "help");
        _ = helpCommand.helpOption(false);
        _ = helpCommand.arguments("[command]");
        _ = helpCommand.description("display help for command");
        return helpCommand;
    }

    //
    // The help command, or null when there is none (`_getHelpCommand`).
    //
    pub fn getHelpCommand(self: *Command) ?*Command {
        const hasImplicitHelpCommand = self.addImplicitHelpCommand orelse
            (self.commands.items.len > 0 and self.actionHandler == null and self.findCommand("help") == null);
        if (hasImplicitHelpCommand) {
            if (self.helpCommandValue == null) {
                self.helpCommandValue = self.createDefaultHelpCommand();
                self.addImplicitHelpCommand = true;
            }
            return self.helpCommandValue;
        }
        return null;
    }

    //
    // Add hook for life cycle event. The hook is called with the context, the command the hook was added to
    // and the command whose action runs.
    //
    pub fn hook(self: *Command, event: HookEvent, context: anytype, comptime listener: fn (@TypeOf(context), *Command, *Command) anyerror!void) *Command {
        const Context = @TypeOf(context);
        const Adapter = struct {
            //
            // Calls the listener with its context cast back.
            //
            fn call(erased: *const anyopaque, thisCommand: *Command, actionCommand: *Command) anyerror!void {
                return listener(castContext(Context, erased), thisCommand, actionCommand);
            }
        };
        self.lifeCycleHooks.append(self.allocator, .{
            .event = event,
            .context = context,
            .function = Adapter.call,
        }) catch @panic("out of memory building the command line");
        return self;
    }

    //
    // Register callback to use as replacement for calling process.exit: errors return error.CommanderError
    // instead of error.Exit.
    //
    pub fn exitOverride(self: *Command) *Command {
        self.exitOverridden = true;
        return self;
    }

    //
    // Call process.exit, and _exitCallback if defined (`_exit`): records the error on the root command and
    // returns error.CommanderError (with exitOverride) or error.Exit (the caller exits with the exit code).
    //
    pub fn exit(self: *Command, exitCode: u8, code: []const u8, message: []const u8) anyerror {
        self.root().commanderError = .{
            .exitCode = exitCode,
            .code = code,
            .message = message,
        };
        if (self.exitOverridden) {
            return error.CommanderError;
        }
        return error.Exit;
    }

    //
    // Register callback `listener` for the command: called with the context, the processed arguments, the
    // option values and the command.
    //
    pub fn action(self: *Command, context: anytype, comptime listener: fn (@TypeOf(context), []const ArgumentValue, *const OptionValues, *Command) anyerror!void) *Command {
        const Context = @TypeOf(context);
        const Adapter = struct {
            //
            // Calls the listener with its context cast back.
            //
            fn call(erased: *const anyopaque, args: []const ArgumentValue, options: *const OptionValues, actionCommand: *Command) anyerror!void {
                return listener(castContext(Context, erased), args, options, actionCommand);
            }
        };
        self.actionHandler = .{
            .context = context,
            .function = Adapter.call,
        };
        return self;
    }

    //
    // Add an option (`addOption`): stores its default value.
    //
    pub fn addOption(self: *Command, added: Option) *Command {
        self.addOptionOrError(added) catch @panic("out of memory building the command line");
        return self;
    }

    //
    // Add an option, returning allocation errors.
    //
    fn addOptionOrError(self: *Command, added: Option) !void {
        try self.options.append(self.allocator, added);
        const attributeName = try added.attributeName(self.allocator);

        // store default value
        if (added.negate) {
            // --no-foo is special and defaults foo to true, unless a --foo option is already defined
            const positiveLongFlag = try std.fmt.allocPrint(self.allocator, "--{s}", .{added.long.?[5..]});
            if (self.findOption(positiveLongFlag) == null) {
                try self.setOptionValue(attributeName, added.defaultValue orelse .{ .boolean = true });
            }
        }
        else if (added.defaultValue) |defaultValue| {
            try self.setOptionValue(attributeName, defaultValue);
        }
    }

    //
    // Handles a value of an option given on the command line (the `option:<name>` listener).
    //
    fn emitOption(self: *Command, target: Option, event: OptionEvent) !void {
        const attributeName = try target.attributeName(self.allocator);
        var value: ?OptionValue = switch (event) {
            .none, .missing => null,
            .text => |text| .{ .string = text },
        };

        // custom processing
        if (event != .missing) {
            if (target.parseArg) |parseArg| {
                const text: ?[]const u8 = switch (event) {
                    .text => |text| text,
                    else => null,
                };
                value = try parseArg.function(parseArg.context, text, self.getOptionValue(attributeName));
            }
        }

        // Fill-in appropriate missing values. Long winded but easy to follow.
        if (value == null) {
            if (target.negate) {
                value = .{ .boolean = false };
            }
            else if (target.isBoolean() or target.optional) {
                value = .{ .boolean = true };
            }
            else {
                value = .{ .string = "" }; // not normal, parseArg might have failed or be a mock function for testing
            }
        }
        try self.setOptionValue(attributeName, value.?);
    }

    //
    // Define option with `flags`, `description`, and an optional default value.
    //
    pub fn option(self: *Command, flags: []const u8, optionDescription: []const u8, defaultValue: ?OptionValue) *Command {
        var created = Option.init(flags, optionDescription);
        created.defaultValue = defaultValue;
        return self.addOption(created);
    }

    //
    // Define option with `flags`, `description` and a function for custom option processing, called with the
    // context (commander `.option(flags, description, fn)`).
    //
    pub fn optionWithArgParser(
        self: *Command,
        flags: []const u8,
        optionDescription: []const u8,
        context: anytype,
        comptime parseArg: fn (@TypeOf(context), ?[]const u8, ?OptionValue) anyerror!?OptionValue,
    ) *Command {
        const Context = @TypeOf(context);
        const Adapter = struct {
            //
            // Calls the parser with its context cast back.
            //
            fn call(erased: *const anyopaque, value: ?[]const u8, previous: ?OptionValue) anyerror!?OptionValue {
                return parseArg(castContext(Context, erased), value, previous);
            }
        };
        var created = Option.init(flags, optionDescription);
        created.parseArg = .{
            .context = context,
            .function = Adapter.call,
        };
        return self.addOption(created);
    }

    //
    // Add a required option which must have a value after parsing. This usually means the option must be
    // specified on the command line.
    //
    pub fn requiredOption(self: *Command, flags: []const u8, optionDescription: []const u8, defaultValue: ?OptionValue) *Command {
        var created = Option.init(flags, optionDescription);
        created.mandatory = true;
        created.defaultValue = defaultValue;
        return self.addOption(created);
    }

    //
    // Retrieve option value.
    //
    pub fn getOptionValue(self: *const Command, key: []const u8) ?OptionValue {
        return self.optionValues.get(key);
    }

    //
    // Store option value.
    //
    pub fn setOptionValue(self: *Command, key: []const u8, value: OptionValue) !void {
        try self.optionValues.put(self.allocator, key, value);
    }

    //
    // Parse `argv` (the user arguments, `{ from: 'user' }`), setting options and invoking commands when
    // defined.
    //
    pub fn parse(self: *Command, argv: []const []const u8) anyerror!void {
        // Find default name for program from arguments.
        if (self.commandName.len == 0) {
            self.commandName = "program";
        }
        try self.parseCommand(&.{}, argv);
    }

    //
    // Process arguments in context of this command (`_parseCommand`).
    //
    fn parseCommand(self: *Command, operandsSoFar: []const []const u8, unknownSoFar: []const []const u8) anyerror!void {
        const parsed = try self.parseOptions(unknownSoFar);
        // Not ported: _parseOptionsEnv and _parseOptionsImplied (psi has no env or implied options).
        var operandList: std.ArrayList([]const u8) = .empty;
        try operandList.appendSlice(self.allocator, operandsSoFar);
        try operandList.appendSlice(self.allocator, parsed.operands);
        const operands = operandList.items;
        const unknown = parsed.unknown;
        var allArgs: std.ArrayList([]const u8) = .empty;
        try allArgs.appendSlice(self.allocator, operands);
        try allArgs.appendSlice(self.allocator, unknown);
        self.args = allArgs.items;

        if (operands.len > 0 and self.findCommand(operands[0]) != null) {
            return self.dispatchSubcommand(operands[0], operands[1..], unknown);
        }
        if (self.getHelpCommand()) |helpCommand| {
            if (operands.len > 0 and std.mem.eql(u8, operands[0], helpCommand.commandName)) {
                return self.dispatchHelpCommand(if (operands.len > 1) operands[1] else null);
            }
        }
        if (self.commands.items.len > 0 and self.args.len == 0 and self.actionHandler == null) {
            // probably missing subcommand and no handler, user needs help (and exit)
            return self.help(true);
        }

        try self.outputHelpIfRequested(parsed.unknown);
        try self.checkForMissingMandatoryOptions();

        if (self.actionHandler) |handler| {
            try self.checkForUnknownOptions(parsed.unknown);
            try self.processArguments();
            try self.callHooks(.preAction);
            try handler.function(handler.context, self.processedArgs, &self.optionValues, self);
            return;
        }
        if (operands.len > 0) {
            if (self.commands.items.len > 0) {
                return self.unknownCommand();
            }
            try self.checkForUnknownOptions(parsed.unknown);
            try self.processArguments();
        }
        else if (self.commands.items.len > 0) {
            try self.checkForUnknownOptions(parsed.unknown);
            // This command has subcommands and nothing hooked up at this level, so display help (and exit).
            return self.help(true);
        }
        else {
            try self.checkForUnknownOptions(parsed.unknown);
            try self.processArguments();
            // fall through for caller to handle after calling .parse()
        }
    }

    //
    // Reports the first unknown option, if any. Not always called, to avoid masking a "better" error, like
    // unknown command.
    //
    fn checkForUnknownOptions(self: *Command, unknown: []const []const u8) !void {
        if (unknown.len > 0) {
            return self.unknownOption(unknown[0]);
        }
    }

    //
    // Hands the remaining arguments to a subcommand (`_dispatchSubcommand`).
    //
    fn dispatchSubcommand(self: *Command, commandName: []const u8, operands: []const []const u8, unknown: []const []const u8) anyerror!void {
        const subCommand = self.findCommand(commandName) orelse {
            return self.help(true);
        };
        return subCommand.parseCommand(operands, unknown);
    }

    //
    // Runs the help command (`_dispatchHelpCommand`).
    //
    fn dispatchHelpCommand(self: *Command, subcommandName: ?[]const u8) anyerror!void {
        const wanted = subcommandName orelse {
            return self.help(false);
        };
        if (self.findCommand(wanted)) |subCommand| {
            return subCommand.help(false);
        }
        // Fallback to parsing the help flag to invoke the help.
        return self.dispatchSubcommand(wanted, &.{}, &.{"--help"});
    }

    //
    // Check this.args against expected this.registeredArguments (`_checkNumberOfArguments`).
    //
    fn checkNumberOfArguments(self: *Command) !void {
        // too few
        for (self.registeredArguments.items, 0..) |declared, index| {
            if (declared.required and index >= self.args.len) {
                return self.missingArgument(declared.name());
            }
        }
        // too many
        const count = self.registeredArguments.items.len;
        if (count > 0 and self.registeredArguments.items[count - 1].variadic) {
            return;
        }
        if (self.args.len > count) {
            return self.excessArguments(self.args);
        }
    }

    //
    // Process this.args using this.registeredArguments and save as this.processedArgs (`_processArguments`).
    //
    fn processArguments(self: *Command) !void {
        try self.checkNumberOfArguments();
        const processed = try self.allocator.alloc(ArgumentValue, self.registeredArguments.items.len);
        for (self.registeredArguments.items, 0..) |declared, index| {
            var value: ArgumentValue = .none;
            if (declared.variadic) {
                // Collect together remaining arguments for passing together as an array.
                if (index < self.args.len) {
                    value = .{ .list = self.args[index..] };
                }
                else {
                    value = .{ .list = &.{} };
                }
            }
            else if (index < self.args.len) {
                value = .{ .string = self.args[index] };
            }
            processed[index] = value;
        }
        self.processedArgs = processed;
    }

    //
    // Calls the hooks for an event, from the root command down to this command (`_chainOrCallHooks`).
    //
    fn callHooks(self: *Command, event: HookEvent) !void {
        const commands = try self.getCommandAndAncestors();
        var index = commands.len;
        while (index > 0) {
            index -= 1;
            const hookedCommand = commands[index];
            for (hookedCommand.lifeCycleHooks.items) |lifeCycleHook| {
                if (lifeCycleHook.event == event) {
                    try lifeCycleHook.function(lifeCycleHook.context, hookedCommand, self);
                }
            }
        }
    }

    //
    // Find matching command by name or alias (`_findCommand`).
    //
    pub fn findCommand(self: *Command, commandName: []const u8) ?*Command {
        for (self.commands.items) |subcommand| {
            if (std.mem.eql(u8, subcommand.commandName, commandName)) {
                return subcommand;
            }
            for (subcommand.aliasList.items) |aliasName| {
                if (std.mem.eql(u8, aliasName, commandName)) {
                    return subcommand;
                }
            }
        }
        return null;
    }

    //
    // Return an option matching `arg` if any (`_findOption`).
    //
    pub fn findOption(self: *const Command, arg: []const u8) ?Option {
        for (self.options.items) |candidate| {
            if (candidate.is(arg)) {
                return candidate;
            }
        }
        return null;
    }

    //
    // Display an error message if a mandatory option does not have a value. Called after checking for help
    // flags in leaf subcommand (`_checkForMissingMandatoryOptions`).
    //
    fn checkForMissingMandatoryOptions(self: *Command) !void {
        // Walk up hierarchy so can call in subcommand after checking for displaying help.
        for (try self.getCommandAndAncestors()) |current| {
            for (current.options.items) |candidate| {
                if (candidate.mandatory and current.getOptionValue(try candidate.attributeName(self.allocator)) == null) {
                    return current.missingMandatoryOptionValue(candidate);
                }
            }
        }
    }

    //
    // Parse options from `argv` removing known options, and return argv split into operands and unknown
    // arguments.
    //
    //     argv => operands, unknown
    //     --known kkk op => [op], []
    //     op --known kkk => [op], []
    //     sub --unknown uuu op => [sub], [--unknown uuu op]
    //     sub -- --unknown uuu op => [sub --unknown uuu op], []
    //
    pub fn parseOptions(self: *Command, argv: []const []const u8) anyerror!IParseOptionsResult {
        var operands: std.ArrayList([]const u8) = .empty; // operands, not options or values
        var unknown: std.ArrayList([]const u8) = .empty; // first unknown option and remaining unknown args
        var destIsUnknown = false;
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(self.allocator, argv);

        // parse options
        while (args.items.len > 0) {
            const arg = args.orderedRemove(0);
            const dest = if (destIsUnknown) &unknown else &operands;

            // literal
            if (std.mem.eql(u8, arg, "--")) {
                if (destIsUnknown) {
                    try dest.append(self.allocator, arg);
                }
                try dest.appendSlice(self.allocator, args.items);
                break;
            }

            // Not ported: activeVariadicOption (psi has no variadic options).

            if (maybeOption(arg)) {
                // recognised option, call listener to assign value with possible custom processing
                if (self.findOption(arg)) |found| {
                    if (found.required) {
                        if (args.items.len == 0) {
                            return self.optionMissingArgument(found);
                        }
                        const value = args.orderedRemove(0);
                        try self.emitOption(found, .{ .text = value });
                    }
                    else if (found.optional) {
                        // historical behaviour is optional value is following arg unless an option
                        if (args.items.len > 0 and !maybeOption(args.items[0])) {
                            try self.emitOption(found, .{ .text = args.orderedRemove(0) });
                        }
                        else {
                            try self.emitOption(found, .missing);
                        }
                    }
                    else {
                        // boolean flag
                        try self.emitOption(found, .none);
                    }
                    continue;
                }
            }

            // Look for combo options following single dash, eat first one if known.
            if (arg.len > 2 and arg[0] == '-' and arg[1] != '-') {
                const shortFlag = try std.fmt.allocPrint(self.allocator, "-{c}", .{arg[1]});
                if (self.findOption(shortFlag)) |found| {
                    if (found.required or found.optional) {
                        // option with value following in same argument
                        try self.emitOption(found, .{ .text = arg[2..] });
                    }
                    else {
                        // boolean option, emit and put back remainder of arg for further processing
                        try self.emitOption(found, .none);
                        try args.insert(self.allocator, 0, try std.fmt.allocPrint(self.allocator, "-{s}", .{arg[2..]}));
                    }
                    continue;
                }
            }

            // Look for known long flag with value, like --foo=bar
            if (std.mem.startsWith(u8, arg, "--")) {
                if (std.mem.indexOfScalar(u8, arg, '=')) |equalsIndex| {
                    if (equalsIndex > 2) {
                        if (self.findOption(arg[0..equalsIndex])) |found| {
                            if (found.required or found.optional) {
                                try self.emitOption(found, .{ .text = arg[equalsIndex + 1 ..] });
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
                destIsUnknown = true;
            }

            // Not ported: positional options and pass through options (psi does not enable them).

            // add arg
            if (destIsUnknown) {
                try unknown.append(self.allocator, arg);
            }
            else {
                try operands.append(self.allocator, arg);
            }
        }

        return .{
            .operands = operands.items,
            .unknown = unknown.items,
        };
    }

    //
    // Return an object containing local option values as key-value pairs.
    //
    pub fn opts(self: *Command) *const OptionValues {
        return &self.optionValues;
    }

    //
    // Display error message and exit (or call exitOverride).
    //
    pub fn @"error"(self: *Command, message: []const u8, errorOptions: IErrorOptions) anyerror {
        // output handling
        const line = std.fmt.allocPrint(self.allocator, "{s}\n", .{message}) catch |err| return err;
        writeTo(self.outputConfiguration.writeErr, std.Io.File.stderr(), line);
        // exit handling
        return self.exit(errorOptions.exitCode, errorOptions.code, message);
    }

    //
    // Argument `name` is missing.
    //
    pub fn missingArgument(self: *Command, argumentName: []const u8) anyerror {
        const message = std.fmt.allocPrint(self.allocator, "error: missing required argument '{s}'", .{argumentName}) catch |err| return err;
        return self.@"error"(message, .{ .code = "commander.missingArgument" });
    }

    //
    // `Option` is missing an argument.
    //
    pub fn optionMissingArgument(self: *Command, target: Option) anyerror {
        const message = std.fmt.allocPrint(self.allocator, "error: option '{s}' argument missing", .{target.flags}) catch |err| return err;
        return self.@"error"(message, .{ .code = "commander.optionMissingArgument" });
    }

    //
    // `Option` does not have a value, and is a mandatory option.
    //
    pub fn missingMandatoryOptionValue(self: *Command, target: Option) anyerror {
        const message = std.fmt.allocPrint(self.allocator, "error: required option '{s}' not specified", .{target.flags}) catch |err| return err;
        return self.@"error"(message, .{ .code = "commander.missingMandatoryOptionValue" });
    }

    //
    // Unknown option `flag`.
    //
    pub fn unknownOption(self: *Command, flag: []const u8) anyerror {
        var suggestion: []const u8 = "";
        if (std.mem.startsWith(u8, flag, "--")) {
            // Looping to pick up the global options too
            var candidateFlags: std.ArrayList([]const u8) = .empty;
            var current: ?*Command = self;
            while (current) |candidateCommand| {
                var helper = Help{};
                const visible = helper.visibleOptions(self.allocator, candidateCommand) catch |err| return err;
                for (visible) |visibleOption| {
                    if (visibleOption.long) |longFlag| {
                        candidateFlags.append(self.allocator, longFlag) catch |err| return err;
                    }
                }
                current = candidateCommand.parent;
            }
            suggestion = suggestSimilar(self.allocator, flag, candidateFlags.items) catch |err| return err;
        }
        const message = std.fmt.allocPrint(self.allocator, "error: unknown option '{s}'{s}", .{ flag, suggestion }) catch |err| return err;
        return self.@"error"(message, .{ .code = "commander.unknownOption" });
    }

    //
    // Excess arguments, more than expected (`_excessArguments`).
    //
    pub fn excessArguments(self: *Command, receivedArgs: []const []const u8) anyerror {
        const expected = self.registeredArguments.items.len;
        const plural = if (expected == 1) "" else "s";
        var forSubcommand: []const u8 = "";
        if (self.parent != null) {
            forSubcommand = std.fmt.allocPrint(self.allocator, " for '{s}'", .{self.commandName}) catch |err| return err;
        }
        const message = std.fmt.allocPrint(self.allocator, "error: too many arguments{s}. Expected {d} argument{s} but got {d}.", .{ forSubcommand, expected, plural, receivedArgs.len }) catch |err| return err;
        return self.@"error"(message, .{ .code = "commander.excessArguments" });
    }

    //
    // Unknown command.
    //
    pub fn unknownCommand(self: *Command) anyerror {
        const unknownName = self.args[0];
        var candidateNames: std.ArrayList([]const u8) = .empty;
        var helper = Help{};
        const visible = helper.visibleCommands(self.allocator, self) catch |err| return err;
        for (visible) |visibleCommand| {
            candidateNames.append(self.allocator, visibleCommand.commandName) catch |err| return err;
            // just visible alias
            if (visibleCommand.getAlias()) |aliasName| {
                candidateNames.append(self.allocator, aliasName) catch |err| return err;
            }
        }
        const suggestion = suggestSimilar(self.allocator, unknownName, candidateNames.items) catch |err| return err;
        const message = std.fmt.allocPrint(self.allocator, "error: unknown command '{s}'{s}", .{ unknownName, suggestion }) catch |err| return err;
        return self.@"error"(message, .{ .code = "commander.unknownCommand" });
    }

    //
    // Set the description.
    //
    pub fn description(self: *Command, text: []const u8) *Command {
        self.descriptionText = text;
        return self;
    }

    //
    // Get the description.
    //
    pub fn getDescription(self: *const Command) []const u8 {
        return self.descriptionText;
    }

    //
    // Set an alias for the command. You may call more than once to add multiple aliases. Only the first
    // alias is shown in the auto-generated help.
    //
    pub fn alias(self: *Command, aliasName: []const u8) *Command {
        self.aliasList.append(self.allocator, aliasName) catch @panic("out of memory building the command line");
        return self;
    }

    //
    // Get the first alias, or null (`alias()`).
    //
    pub fn getAlias(self: *const Command) ?[]const u8 {
        if (self.aliasList.items.len == 0) {
            return null;
        }
        return self.aliasList.items[0];
    }

    //
    // Set aliases for the command.
    //
    pub fn aliases(self: *Command, aliasNames: []const []const u8) *Command {
        for (aliasNames) |aliasName| {
            _ = self.alias(aliasName);
        }
        return self;
    }

    //
    // Get the aliases (`aliases()`).
    //
    pub fn getAliases(self: *const Command) []const []const u8 {
        return self.aliasList.items;
    }

    //
    // Get the command usage to be displayed at the top of the built-in help (`usage()`).
    //
    pub fn usage(self: *const Command, allocator: std.mem.Allocator) ![]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        if (self.options.items.len > 0 or self.helpOptionEnabled) {
            try parts.append(allocator, "[options]");
        }
        if (self.commands.items.len > 0) {
            try parts.append(allocator, "[command]");
        }
        for (self.registeredArguments.items) |declared| {
            try parts.append(allocator, try humanReadableArgName(allocator, declared));
        }
        return std.mem.join(allocator, " ", parts.items);
    }

    //
    // Set the name of the command.
    //
    pub fn name(self: *Command, text: []const u8) *Command {
        self.commandName = text;
        return self;
    }

    //
    // Get the name of the command.
    //
    pub fn getName(self: *const Command) []const u8 {
        return self.commandName;
    }

    //
    // Return program help documentation.
    //
    pub fn helpInformation(self: *Command, isError: bool) ![]const u8 {
        var helper = Help{};
        const context = self.getOutputContext(isError);
        helper.prepareContext(context.helpWidth);
        const text = try helper.formatHelp(self.allocator, self);
        if (context.hasColors) {
            return text;
        }
        return stripColor(self.allocator, text);
    }

    //
    // Where help goes, and how (`_getOutputContext`).
    //
    fn getOutputContext(self: *Command, isError: bool) IOutputContext {
        if (isError) {
            return .{
                .isError = true,
                .hasColors = self.outputConfiguration.getErrHasColors(),
                .helpWidth = self.outputConfiguration.getErrHelpWidth(),
                .command = self,
            };
        }
        return .{
            .isError = false,
            .hasColors = self.outputConfiguration.getOutHasColors(),
            .helpWidth = self.outputConfiguration.getOutHelpWidth(),
            .command = self,
        };
    }

    //
    // Writes the text added at a position (the `*Help` listeners): the text and a newline, when not empty.
    //
    fn writeHelpTexts(self: *Command, position: HelpTextPosition, context: IOutputContext) !void {
        for (self.helpTexts.items) |helpText| {
            if (helpText.position == position and helpText.text.len > 0) {
                try context.write(self.allocator, try std.fmt.allocPrint(self.allocator, "{s}\n", .{helpText.text}));
            }
        }
    }

    //
    // Output help information for this command (to stderr when isError).
    //
    pub fn outputHelp(self: *Command, isError: bool) !void {
        const outputContext = self.getOutputContext(isError);
        const commands = try self.getCommandAndAncestors();
        var index = commands.len;
        while (index > 0) {
            index -= 1;
            try commands[index].writeHelpTexts(.beforeAll, outputContext);
        }
        try self.writeHelpTexts(.before, outputContext);
        try outputContext.write(self.allocator, try self.helpInformation(outputContext.isError));
        try self.writeHelpTexts(.after, outputContext);
        for (commands) |current| {
            try current.writeHelpTexts(.afterAll, outputContext);
        }
    }

    //
    // Turn the built-in help option on or off (`helpOption(false)`).
    //
    pub fn helpOption(self: *Command, enable: bool) *Command {
        self.helpOptionEnabled = enable;
        return self;
    }

    //
    // The built-in help option, or null when it is disabled (`_getHelpOption`).
    //
    pub fn getHelpOption(self: *const Command) ?Option {
        if (!self.helpOptionEnabled) {
            return null;
        }
        return Option.init("-h, --help", "display help for command");
    }

    //
    // Output help information and exit (to stderr with exit code 1 when isError).
    //
    pub fn help(self: *Command, isError: bool) anyerror {
        self.outputHelp(isError) catch |err| return err;
        const exitCode: u8 = if (isError) 1 else 0;
        // message: do not have all displayed text available so only passing placeholder.
        return self.exit(exitCode, "commander.help", "(outputHelp)");
    }

    //
    // Add additional text to be displayed with the built-in help.
    //
    pub fn addHelpText(self: *Command, position: HelpTextPosition, text: []const u8) *Command {
        self.helpTexts.append(self.allocator, .{
            .position = position,
            .text = text,
        }) catch @panic("out of memory building the command line");
        return self;
    }

    //
    // Output help information if help flags specified (`_outputHelpIfRequested`).
    //
    fn outputHelpIfRequested(self: *Command, args: []const []const u8) !void {
        const helpOptionValue = self.getHelpOption() orelse return;
        for (args) |arg| {
            if (helpOptionValue.is(arg)) {
                try self.outputHelp(false);
                // (Do not have all displayed text available so only passing placeholder.)
                return self.exit(0, "commander.helpDisplayed", "(outputHelp)");
            }
        }
    }

    //
    // Configure output: where it goes and what the destination can show.
    //
    pub fn configureOutput(self: *Command, configuration: IOutputConfiguration) *Command {
        self.outputConfiguration.* = configuration;
        return self;
    }
};

//
// True when an argument could be an option (`arg.length > 1 && arg[0] === '-'`).
//
fn maybeOption(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '-';
}

//
// Formats help (commander `Help`, with the default settings: no sorting, no global options, no styles).
//
pub const Help = struct {
    // The width the help is wrapped to, or null before prepareContext.
    helpWidth: ?usize = null,

    // Descriptions narrower than this are not wrapped.
    minWidthToWrap: usize = 40,

    //
    // Prepare the help: the width comes from the output destination, else 80.
    //
    pub fn prepareContext(self: *Help, contextHelpWidth: ?usize) void {
        self.helpWidth = self.helpWidth orelse contextHelpWidth orelse 80;
    }

    //
    // Get an array of the visible subcommands. Includes a placeholder for the implicit help command, if
    // there is one.
    //
    pub fn visibleCommands(self: *const Help, allocator: std.mem.Allocator, cmd: *Command) ![]const *Command {
        _ = self;
        var visible: std.ArrayList(*Command) = .empty;
        for (cmd.commands.items) |subcommand| {
            if (!subcommand.hidden) {
                try visible.append(allocator, subcommand);
            }
        }
        if (cmd.getHelpCommand()) |helpCommand| {
            if (!helpCommand.hidden) {
                try visible.append(allocator, helpCommand);
            }
        }
        return visible.items;
    }

    //
    // Get an array of the visible options. Includes a placeholder for the implicit help option, if there is
    // one.
    //
    pub fn visibleOptions(self: *const Help, allocator: std.mem.Allocator, cmd: *const Command) ![]const Option {
        _ = self;
        var visible: std.ArrayList(Option) = .empty;
        try visible.appendSlice(allocator, cmd.options.items);
        // Built-in help option.
        if (cmd.getHelpOption()) |helpOptionValue| {
            // Automatically hide conflicting flags. Bit dubious but a historical behaviour that is convenient for single-command programs.
            const removeShort = helpOptionValue.short != null and cmd.findOption(helpOptionValue.short.?) != null;
            const removeLong = helpOptionValue.long != null and cmd.findOption(helpOptionValue.long.?) != null;
            if (!removeShort and !removeLong) {
                try visible.append(allocator, helpOptionValue); // no changes needed
            }
            else if (helpOptionValue.long != null and !removeLong) {
                try visible.append(allocator, Option.init(helpOptionValue.long.?, helpOptionValue.description));
            }
            else if (helpOptionValue.short != null and !removeShort) {
                try visible.append(allocator, Option.init(helpOptionValue.short.?, helpOptionValue.description));
            }
        }
        return visible.items;
    }

    //
    // Get an array of the arguments if any have a description.
    //
    pub fn visibleArguments(self: *const Help, cmd: *const Command) []const Argument {
        _ = self;
        // If there are any arguments with a description then return all the arguments.
        for (cmd.registeredArguments.items) |declared| {
            if (declared.description.len > 0) {
                return cmd.registeredArguments.items;
            }
        }
        return &.{};
    }

    //
    // Get the command term to show in the list of subcommands.
    //
    pub fn subcommandTerm(self: *const Help, allocator: std.mem.Allocator, cmd: *const Command) ![]const u8 {
        _ = self;
        // Legacy. Ignores custom usage string, and nested commands.
        var names: std.ArrayList([]const u8) = .empty;
        for (cmd.registeredArguments.items) |declared| {
            try names.append(allocator, try humanReadableArgName(allocator, declared));
        }
        const args = try std.mem.join(allocator, " ", names.items);
        var term: std.ArrayList(u8) = .empty;
        try term.appendSlice(allocator, cmd.commandName);
        if (cmd.getAlias()) |aliasName| {
            try term.print(allocator, "|{s}", .{aliasName});
        }
        if (cmd.options.items.len > 0) {
            try term.appendSlice(allocator, " [options]"); // simplistic check for non-help option
        }
        if (args.len > 0) {
            try term.print(allocator, " {s}", .{args});
        }
        return term.items;
    }

    //
    // Get the option term to show in the list of options.
    //
    pub fn optionTerm(self: *const Help, option: Option) []const u8 {
        _ = self;
        return option.flags;
    }

    //
    // Get the argument term to show in the list of arguments.
    //
    pub fn argumentTerm(self: *const Help, declared: Argument) []const u8 {
        _ = self;
        return declared.name();
    }

    //
    // Get the longest command term length.
    //
    pub fn longestSubcommandTermLength(self: *const Help, allocator: std.mem.Allocator, cmd: *Command) !usize {
        var longest: usize = 0;
        for (try self.visibleCommands(allocator, cmd)) |subcommand| {
            longest = @max(longest, displayWidth(try self.subcommandTerm(allocator, subcommand)));
        }
        return longest;
    }

    //
    // Get the longest option term length.
    //
    pub fn longestOptionTermLength(self: *const Help, allocator: std.mem.Allocator, cmd: *const Command) !usize {
        var longest: usize = 0;
        for (try self.visibleOptions(allocator, cmd)) |visibleOption| {
            longest = @max(longest, displayWidth(self.optionTerm(visibleOption)));
        }
        return longest;
    }

    //
    // Get the longest argument term length.
    //
    pub fn longestArgumentTermLength(self: *const Help, cmd: *const Command) usize {
        var longest: usize = 0;
        for (self.visibleArguments(cmd)) |declared| {
            longest = @max(longest, displayWidth(self.argumentTerm(declared)));
        }
        return longest;
    }

    //
    // Get the command usage to be displayed at the top of the built-in help.
    //
    pub fn commandUsage(self: *const Help, allocator: std.mem.Allocator, cmd: *const Command) ![]const u8 {
        _ = self;
        // Usage
        var cmdName = cmd.commandName;
        if (cmd.getAlias()) |aliasName| {
            cmdName = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ cmdName, aliasName });
        }
        var ancestorCmdNames: []const u8 = "";
        var ancestor = cmd.parent;
        while (ancestor) |ancestorCmd| {
            ancestorCmdNames = try std.fmt.allocPrint(allocator, "{s} {s}", .{ ancestorCmd.commandName, ancestorCmdNames });
            ancestor = ancestorCmd.parent;
        }
        return std.fmt.allocPrint(allocator, "{s}{s} {s}", .{ ancestorCmdNames, cmdName, try cmd.usage(allocator) });
    }

    //
    // Get the description for the command.
    //
    pub fn commandDescription(self: *const Help, cmd: *const Command) []const u8 {
        _ = self;
        return cmd.getDescription();
    }

    //
    // Get the subcommand summary to show in the list of subcommands (the description; summaries are not ported).
    //
    pub fn subcommandDescription(self: *const Help, cmd: *const Command) []const u8 {
        _ = self;
        return cmd.getDescription();
    }

    //
    // Get the option description to show in the list of options.
    //
    pub fn optionDescription(self: *const Help, allocator: std.mem.Allocator, option: Option) ![]const u8 {
        _ = self;
        if (option.defaultValue) |defaultValue| {
            // default for boolean and negated more for programmer than end user,
            // but show true/false for boolean option as may be for hand-rolled env or config processing.
            const showDefault = option.required or option.optional or (option.isBoolean() and defaultValue == .boolean);
            if (showDefault) {
                return std.fmt.allocPrint(allocator, "{s} (default: {s})", .{ option.description, try stringifyOptionValue(allocator, defaultValue) });
            }
        }
        return option.description;
    }

    //
    // Get the argument description to show in the list of arguments.
    //
    pub fn argumentDescription(self: *const Help, declared: Argument) []const u8 {
        _ = self;
        return declared.description;
    }

    //
    // Generate the built-in help text.
    //
    pub fn formatHelp(self: *const Help, allocator: std.mem.Allocator, cmd: *Command) ![]const u8 {
        const termWidth = try self.padWidth(allocator, cmd);
        const helpWidth = self.helpWidth orelse 80; // in case prepareContext() was not called

        // Usage
        var output: std.ArrayList([]const u8) = .empty;
        try output.append(allocator, try std.fmt.allocPrint(allocator, "Usage: {s}", .{try self.commandUsage(allocator, cmd)}));
        try output.append(allocator, "");

        // Description
        const commandDescriptionText = self.commandDescription(cmd);
        if (commandDescriptionText.len > 0) {
            try output.append(allocator, try self.boxWrap(allocator, commandDescriptionText, helpWidth));
            try output.append(allocator, "");
        }

        // Arguments
        const argumentList = self.visibleArguments(cmd);
        if (argumentList.len > 0) {
            try output.append(allocator, "Arguments:");
            for (argumentList) |declared| {
                try output.append(allocator, try self.formatItem(allocator, self.argumentTerm(declared), termWidth, self.argumentDescription(declared)));
            }
            try output.append(allocator, "");
        }

        // Options
        const optionList = try self.visibleOptions(allocator, cmd);
        if (optionList.len > 0) {
            try output.append(allocator, "Options:");
            for (optionList) |visibleOption| {
                try output.append(allocator, try self.formatItem(allocator, self.optionTerm(visibleOption), termWidth, try self.optionDescription(allocator, visibleOption)));
            }
            try output.append(allocator, "");
        }

        // Not ported: global options (showGlobalOptions is off).

        // Commands
        const commandList = try self.visibleCommands(allocator, cmd);
        if (commandList.len > 0) {
            try output.append(allocator, "Commands:");
            for (commandList) |subcommand| {
                try output.append(allocator, try self.formatItem(allocator, try self.subcommandTerm(allocator, subcommand), termWidth, self.subcommandDescription(subcommand)));
            }
            try output.append(allocator, "");
        }

        return std.mem.join(allocator, "\n", output.items);
    }

    //
    // Calculate the pad width from the maximum term length.
    //
    pub fn padWidth(self: *const Help, allocator: std.mem.Allocator, cmd: *Command) !usize {
        return @max(
            try self.longestOptionTermLength(allocator, cmd),
            try self.longestSubcommandTermLength(allocator, cmd),
            self.longestArgumentTermLength(cmd),
        );
    }

    //
    // Detect manually wrapped and indented strings by checking for line break followed by whitespace
    // (/\n[^\S\r\n]/).
    //
    pub fn preformatted(self: *const Help, text: []const u8) bool {
        _ = self;
        var index: usize = 0;
        while (index < text.len) {
            if (text[index] == '\n' and index + 1 < text.len) {
                const next = decodeCodepoint(text, index + 1);
                if (isJsWhitespace(next.codepoint) and next.codepoint != '\r' and next.codepoint != '\n') {
                    return true;
                }
            }
            index += 1;
        }
        return false;
    }

    //
    // Format the "item", which consists of a term and description. Pad the term and wrap the description,
    // indenting the following lines.
    //
    // So "TTT", 5, "DDD DDDD DD DDD" might be formatted for this.helpWidth=17 like so:
    //   TTT  DDD DDDD
    //        DD DDD
    //
    pub fn formatItem(self: *const Help, allocator: std.mem.Allocator, term: []const u8, termWidth: usize, itemDescription: []const u8) ![]const u8 {
        const itemIndent = 2;
        const itemIndentStr = "  ";
        if (itemDescription.len == 0) {
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ itemIndentStr, term });
        }

        // Pad the term out to a consistent width, so descriptions are aligned.
        var paddedTerm: std.ArrayList(u8) = .empty;
        try paddedTerm.appendSlice(allocator, term);
        const termDisplayWidth = displayWidth(term);
        if (termDisplayWidth < termWidth) {
            try paddedTerm.appendNTimes(allocator, ' ', termWidth - termDisplayWidth);
        }

        // Format the description.
        const spacerWidth = 2; // between term and description
        const helpWidth: i64 = @intCast(self.helpWidth orelse 80); // in case prepareContext() was not called
        const remainingWidth = helpWidth - @as(i64, @intCast(termWidth)) - spacerWidth - itemIndent;
        var formattedDescription: []const u8 = undefined;
        if (remainingWidth < @as(i64, @intCast(self.minWidthToWrap)) or self.preformatted(itemDescription)) {
            formattedDescription = itemDescription;
        }
        else {
            const wrappedDescription = try self.boxWrap(allocator, itemDescription, @intCast(remainingWidth));
            const indent = try allocator.alloc(u8, termWidth + spacerWidth + 1);
            indent[0] = '\n';
            @memset(indent[1..], ' ');
            formattedDescription = try std.mem.replaceOwned(u8, allocator, wrappedDescription, "\n", indent);
        }

        // Construct and overall indent.
        const indentedDescription = try std.mem.replaceOwned(u8, allocator, formattedDescription, "\n", "\n" ++ itemIndentStr);
        return std.fmt.allocPrint(allocator, "{s}{s}  {s}", .{ itemIndentStr, paddedTerm.items, indentedDescription });
    }

    //
    // Wrap a string at whitespace, preserving existing line breaks. Wrapping is skipped if the width is less
    // than `minWidthToWrap`.
    //
    pub fn boxWrap(self: *const Help, allocator: std.mem.Allocator, text: []const u8, width: usize) ![]const u8 {
        if (width < self.minWidthToWrap) {
            return text;
        }

        var wrappedLines: std.ArrayList([]const u8) = .empty;
        var lineStart: usize = 0;
        while (lineStart <= text.len) {
            // split /\r\n|\n/
            var lineEnd = std.mem.indexOfScalarPos(u8, text, lineStart, '\n') orelse text.len;
            const nextStart = lineEnd + 1;
            if (lineEnd > lineStart and lineEnd < text.len and text[lineEnd - 1] == '\r') {
                lineEnd -= 1;
            }
            try wrapLine(allocator, text[lineStart..lineEnd], width, &wrappedLines);
            lineStart = nextStart;
        }
        return std.mem.join(allocator, "\n", wrappedLines.items);
    }
};

//
// Wraps one line of `boxWrap`: splits it into chunks of whitespace followed by non-whitespace
// (/[\s]*[^\s]+/g) and accumulates chunks while they fit into the width.
//
fn wrapLine(allocator: std.mem.Allocator, line: []const u8, width: usize, wrappedLines: *std.ArrayList([]const u8)) !void {
    var chunks: std.ArrayList([]const u8) = .empty;
    var position: usize = 0;
    while (position < line.len) {
        var chunkEnd = position;
        while (chunkEnd < line.len) {
            const decoded = decodeCodepoint(line, chunkEnd);
            if (!isJsWhitespace(decoded.codepoint)) {
                break;
            }
            chunkEnd += decoded.length;
        }
        if (chunkEnd == line.len) {
            break;
        }
        while (chunkEnd < line.len) {
            const decoded = decodeCodepoint(line, chunkEnd);
            if (isJsWhitespace(decoded.codepoint)) {
                break;
            }
            chunkEnd += decoded.length;
        }
        try chunks.append(allocator, line[position..chunkEnd]);
        position = chunkEnd;
    }
    if (chunks.items.len == 0) {
        try wrappedLines.append(allocator, "");
        return;
    }

    var sumChunks: std.ArrayList(u8) = .empty;
    try sumChunks.appendSlice(allocator, chunks.items[0]);
    var sumWidth = displayWidth(chunks.items[0]);
    for (chunks.items[1..]) |chunk| {
        const visibleWidth = displayWidth(chunk);
        // Accumulate chunks while they fit into width.
        if (sumWidth + visibleWidth <= width) {
            try sumChunks.appendSlice(allocator, chunk);
            sumWidth += visibleWidth;
            continue;
        }
        try wrappedLines.append(allocator, sumChunks.items);

        const nextChunk = trimStartJs(chunk); // trim space at line break
        sumChunks = .empty;
        try sumChunks.appendSlice(allocator, nextChunk);
        sumWidth = displayWidth(nextChunk);
    }
    try wrappedLines.append(allocator, sumChunks.items);
}

//
// A decoded UTF-8 code point and the number of bytes it takes.
//
const IDecodedCodepoint = struct {
    // The code point (U+FFFD for an invalid byte).
    codepoint: u21,

    // The number of bytes.
    length: usize,
};

//
// Decodes the code point at a byte index (an invalid byte decodes to U+FFFD and takes one byte).
//
fn decodeCodepoint(text: []const u8, index: usize) IDecodedCodepoint {
    const invalid: IDecodedCodepoint = .{
        .codepoint = 0xFFFD,
        .length = 1,
    };
    const length = std.unicode.utf8ByteSequenceLength(text[index]) catch return invalid;
    if (index + length > text.len) {
        return invalid;
    }
    const codepoint = std.unicode.utf8Decode(text[index .. index + length]) catch return invalid;
    return .{
        .codepoint = codepoint,
        .length = length,
    };
}

//
// True for the characters JavaScript's `\s` matches (and `trimStart` removes).
//
pub fn isJsWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        '\t', '\n', 0x0B, 0x0C, '\r', ' ', 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        0x2000...0x200A => true,
        else => false,
    };
}

//
// Removes the leading whitespace (`String.prototype.trimStart`).
//
fn trimStartJs(text: []const u8) []const u8 {
    var index: usize = 0;
    while (index < text.len) {
        const decoded = decodeCodepoint(text, index);
        if (!isJsWhitespace(decoded.codepoint)) {
            break;
        }
        index += decoded.length;
    }
    return text[index..];
}

//
// The length of a string in JavaScript (UTF-16 code units).
//
pub fn jsLength(text: []const u8) usize {
    var length: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const decoded = decodeCodepoint(text, index);
        length += if (decoded.codepoint >= 0x10000) 2 else 1;
        index += decoded.length;
    }
    return length;
}

//
// Calculate the display width of a string: its length with the SGR color sequences removed.
//
pub fn displayWidth(text: []const u8) usize {
    var length: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const sequenceLength = sgrSequenceLength(text, index);
        if (sequenceLength > 0) {
            index += sequenceLength;
            continue;
        }
        const decoded = decodeCodepoint(text, index);
        length += if (decoded.codepoint >= 0x10000) 2 else 1;
        index += decoded.length;
    }
    return length;
}

//
// The length of the SGR sequence (/\x1b\[\d*(;\d*)*m/) at a byte index, or 0 when there is none.
//
fn sgrSequenceLength(text: []const u8, index: usize) usize {
    if (index + 1 >= text.len or text[index] != 0x1b or text[index + 1] != '[') {
        return 0;
    }
    var position = index + 2;
    while (position < text.len and (std.ascii.isDigit(text[position]) or text[position] == ';')) {
        position += 1;
    }
    if (position < text.len and text[position] == 'm') {
        return position + 1 - index;
    }
    return 0;
}

//
// Strip style ANSI escape sequences from the string. In particular, SGR (Select Graphic Rendition) codes.
//
pub fn stripColor(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, 0x1b) == null) {
        return text;
    }
    var result: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        const sequenceLength = sgrSequenceLength(text, index);
        if (sequenceLength > 0) {
            index += sequenceLength;
            continue;
        }
        try result.append(allocator, text[index]);
        index += 1;
    }
    return result.items;
}

//
// `JSON.stringify` of an option value, as the help shows defaults.
//
pub fn stringifyOptionValue(allocator: std.mem.Allocator, value: OptionValue) ![]const u8 {
    return switch (value) {
        .boolean => |flag| if (flag) "true" else "false",
        .string => |text| std.json.Stringify.valueAlloc(allocator, text, .{}),
    };
}

//
// The maximum edit distance of a suggestion.
//
const maxDistance = 3;

//
// The UTF-16 code units of a string (what JavaScript indexes a string by).
//
fn utf16Units(allocator: std.mem.Allocator, text: []const u8) ![]const u16 {
    var units: std.ArrayList(u16) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        const decoded = decodeCodepoint(text, index);
        if (decoded.codepoint >= 0x10000) {
            const offset = decoded.codepoint - 0x10000;
            try units.append(allocator, @intCast(0xD800 + (offset >> 10)));
            try units.append(allocator, @intCast(0xDC00 + (offset & 0x3FF)));
        }
        else {
            try units.append(allocator, @intCast(decoded.codepoint));
        }
        index += decoded.length;
    }
    return units.items;
}

//
// The optimal string alignment distance (Damerau-Levenshtein, no substring edited more than once), counted in
// UTF-16 code units like JavaScript.
//
pub fn editDistance(allocator: std.mem.Allocator, firstText: []const u8, secondText: []const u8) !usize {
    const first = try utf16Units(allocator, firstText);
    const second = try utf16Units(allocator, secondText);

    // Quick early exit, return worst case.
    const lengthDifference = if (first.len > second.len) first.len - second.len else second.len - first.len;
    if (lengthDifference > maxDistance) {
        return @max(first.len, second.len);
    }

    // distance between prefix substrings of first and second
    const columns = second.len + 1;
    const distances = try allocator.alloc(usize, (first.len + 1) * columns);

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
        var candidate = fullCandidate;
        if (searchingOptions) {
            candidate = fullCandidate[@min(2, fullCandidate.len)..];
        }
        if (jsLength(candidate) <= 1) {
            continue; // no one character guesses
        }

        const distance = try editDistance(allocator, searchWord, candidate);
        const length = @max(jsLength(searchWord), jsLength(candidate));
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
        if (searchingOptions) {
            try shown.append(allocator, try std.fmt.allocPrint(allocator, "--{s}", .{candidate}));
        }
        else {
            try shown.append(allocator, candidate);
        }
    }

    if (shown.items.len > 1) {
        return std.fmt.allocPrint(allocator, "\n(Did you mean one of {s}?)", .{try std.mem.join(allocator, ", ", shown.items)});
    }
    if (shown.items.len == 1) {
        return std.fmt.allocPrint(allocator, "\n(Did you mean {s}?)", .{shown.items[0]});
    }
    return "";
}
