//
// Generates the golden fixtures of apps/cli-zig/src/test/commander.test.zig and main.test.zig from commander.js
// (the version the psi CLI resolves) and from the real TypeScript CLI.
//
// programs.json: programs described as data (the same definitions build the program in commander.js here and
// in the Zig port in the test), each with command lines and what parsing them did: stdout, stderr, the error or
// exit, and the hooks, actions and option parsers that ran with what they were given.
//
// psi.json: command lines of the replicate and verify commands run through the real CLI (apps/cli/index.ts),
// with their stdout, stderr and exit code.
//
// Run from the repo root: bun run apps/cli-zig/src/test/fixtures/commander/generate.ts
//
import { writeFileSync } from "fs";
import { join } from "path";
import { spawnSync } from "child_process";
import { Command, CommanderError } from "commander";

const fixturesDir = import.meta.dir;
const cliDir = join(fixturesDir, "../../../../../cli");

//
// An option of a command definition.
//
interface IOptionDefinition {
    // The flags.
    flags: string;

    // The help text.
    description: string;

    // The default value.
    defaultValue?: boolean | string;

    // True for `.requiredOption`.
    mandatory?: boolean;

    // A custom processing function: "record" records the call and returns "parsed:<value>", "throw" throws.
    parser?: "record" | "throw";
}

//
// An argument of a command definition.
//
interface IArgumentDefinition {
    // The declaration, e.g. "<files...>".
    name: string;

    // The help text.
    description: string;
}

//
// Text added around the help of a command definition.
//
interface IHelpTextDefinition {
    // Where the text goes.
    position: "beforeAll" | "before" | "after" | "afterAll";

    // The text.
    text: string;
}

//
// A command described as data.
//
interface ICommandDefinition {
    // The name (with arguments, for `.command()`).
    name: string;

    // How the command is added to its parent: `.command()` (the default) or `.addCommand(new Command(name))`.
    attach?: "command" | "addCommand";

    // Hides the command from the help.
    hidden?: boolean;

    // The description.
    description?: string;

    // The aliases.
    aliases?: string[];

    // The arguments.
    arguments?: IArgumentDefinition[];

    // The options.
    options?: IOptionDefinition[];

    // The text added around the help.
    helpTexts?: IHelpTextDefinition[];

    // True to call `.exitOverride()`.
    exitOverride?: boolean;

    // The argument of `.addHelpCommand()`, when it is called.
    addHelpCommand?: boolean;

    // True to add a recording preAction hook.
    preActionHook?: boolean;

    // True to add a recording action.
    action?: boolean;

    // The subcommands.
    commands?: ICommandDefinition[];
}

//
// A program and the command lines it is tested with.
//
interface IProgramDefinition {
    // What the program tests.
    title: string;

    // The help width the output reports (undefined: 80).
    helpWidth?: number;

    // True when the output reports that it shows colors.
    colors: boolean;

    // The program.
    program: ICommandDefinition;

    // The command lines (user arguments).
    cases: string[][];
}

//
// Thrown by the stand-in for process.exit, so that the generator survives commander exiting.
//
class ProcessExit extends Error {
    // The exit code passed to process.exit.
    exitCode: number;

    constructor(exitCode: number) {
        super("process.exit");
        this.exitCode = exitCode;
    }
}

//
// What a parse writes and records.
//
interface IRecording {
    // Everything written to stdout.
    stdout: string;

    // Everything written to stderr.
    stderr: string;

    // The hooks, actions and option parsers that ran.
    events: any[];
}

//
// Converts a value for JSON (undefined becomes null).
//
function jsonValue(value: any): any {
    return value === undefined ? null : value;
}

//
// Builds a command from its definition.
//
function buildCommand(command: Command, definition: ICommandDefinition, recording: IRecording, helpWidth: number | undefined, colors: boolean): void {
    if (definition.description !== undefined) {
        command.description(definition.description);
    }
    for (const alias of definition.aliases ?? []) {
        command.alias(alias);
    }
    for (const argument of definition.arguments ?? []) {
        command.argument(argument.name, argument.description);
    }
    for (const option of definition.options ?? []) {
        const add = option.mandatory ? command.requiredOption.bind(command) : command.option.bind(command);
        if (option.parser === "record") {
            add(option.flags, option.description, (value: any, previous: any) => {
                recording.events.push({
                    parser: option.flags,
                    value: jsonValue(value),
                    previous: jsonValue(previous),
                });
                return `parsed:${value}`;
            }, option.defaultValue);
        }
        else if (option.parser === "throw") {
            add(option.flags, option.description, () => {
                throw new Error("parser failed");
            }, option.defaultValue);
        }
        else {
            add(option.flags, option.description, option.defaultValue);
        }
    }
    for (const helpText of definition.helpTexts ?? []) {
        command.addHelpText(helpText.position, helpText.text);
    }
    if (definition.exitOverride) {
        command.exitOverride();
    }
    if (definition.addHelpCommand !== undefined) {
        command.addHelpCommand(definition.addHelpCommand);
    }
    if (definition.preActionHook) {
        command.hook("preAction", (thisCommand, actionCommand) => {
            recording.events.push({
                hook: thisCommand.name(),
                actionCommand: actionCommand.name(),
                opts: {
                    ...thisCommand.opts(),
                },
            });
        });
    }
    if (definition.action) {
        command.action(function (this: Command, ...args: any[]) {
            const actionCommand: Command = args[args.length - 1];
            const options = args[args.length - 2];
            const processedArgs = args.slice(0, args.length - 2).map(jsonValue);
            recording.events.push({
                action: actionCommand.name(),
                args: processedArgs,
                opts: {
                    ...options,
                },
            });
        });
    }
    for (const subDefinition of definition.commands ?? []) {
        let subcommand: Command;
        if (subDefinition.attach === "addCommand") {
            subcommand = new Command(subDefinition.name);
            configureOutput(subcommand, recording, helpWidth, colors);
            command.addCommand(subcommand);
        }
        else {
            subcommand = command.command(subDefinition.name, {
                hidden: subDefinition.hidden === true,
            });
        }
        buildCommand(subcommand, subDefinition, recording, helpWidth, colors);
    }
}

//
// Sends the output of a command (and of the subcommands that share its configuration) to the recording.
//
function configureOutput(command: Command, recording: IRecording, helpWidth: number | undefined, colors: boolean): void {
    command.configureOutput({
        writeOut: (text: string) => {
            recording.stdout += text;
        },
        writeErr: (text: string) => {
            recording.stderr += text;
        },
        getOutHelpWidth: () => helpWidth as number,
        getErrHelpWidth: () => helpWidth as number,
        getOutHasColors: () => colors,
        getErrHasColors: () => colors,
    });
}

//
// Parses a command line with a program built from its definition and returns what happened.
//
function runCase(definition: IProgramDefinition, argv: string[]): any {
    const recording: IRecording = {
        stdout: "",
        stderr: "",
        events: [],
    };
    const program = new Command(definition.program.name);
    configureOutput(program, recording, definition.helpWidth, definition.colors);
    buildCommand(program, definition.program, recording, definition.helpWidth, definition.colors);

    let result: any = {
        kind: "ok",
    };
    const realExit = process.exit;
    process.exit = ((code?: number) => {
        throw new ProcessExit(code ?? 0);
    }) as any;
    try {
        program.parse(argv, {
            from: "user",
        });
    }
    catch (error: any) {
        if (error instanceof ProcessExit) {
            result = {
                kind: "exit",
                exitCode: error.exitCode,
            };
        }
        else if (error instanceof CommanderError) {
            result = {
                kind: "commanderError",
                exitCode: error.exitCode,
                code: error.code,
                message: error.message,
            };
        }
        else {
            result = {
                kind: "thrown",
                message: error.message,
            };
        }
    }
    finally {
        process.exit = realExit;
    }
    return { argv, stdout: recording.stdout, stderr: recording.stderr, result, events: recording.events };
}

//
// An option without a default (`.option(flags, description)`).
//
function option(flags: string, description: string): IOptionDefinition {
    return {
        flags,
        description,
    };
}

//
// An option with a default value (`.option(flags, description, defaultValue)`).
//
function defaultedOption(flags: string, description: string, defaultValue: boolean | string): IOptionDefinition {
    return {
        flags,
        description,
        defaultValue,
    };
}

//
// A required option (`.requiredOption(flags, description)`).
//
function requiredOption(flags: string, description: string): IOptionDefinition {
    return {
        flags,
        description,
        mandatory: true,
    };
}

//
// A required option with a default value (`.requiredOption(flags, description, defaultValue)`).
//
function requiredDefaultedOption(flags: string, description: string, defaultValue: string): IOptionDefinition {
    return {
        flags,
        description,
        mandatory: true,
        defaultValue,
    };
}

//
// An option with a custom processing function.
//
function parsedOption(flags: string, description: string, parser: "record" | "throw"): IOptionDefinition {
    return {
        flags,
        description,
        parser,
    };
}

//
// A command argument.
//
function argument(name: string, description: string): IArgumentDefinition {
    return {
        name,
        description,
    };
}

//
// Text added around the help.
//
function helpText(position: "beforeAll" | "before" | "after" | "afterAll", text: string): IHelpTextDefinition {
    return {
        position,
        text,
    };
}

//
// The options every command of the psi-shaped program shares.
//
const verboseOption: IOptionDefinition = defaultedOption("-v, --verbose", "Enables verbose logging.", false);

const programs: IProgramDefinition[] = [
    {
        title: "options, arguments and help text of a single command",
        colors: false,
        program: {
            name: "tool",
            description: "A tool that does things with files.",
            arguments: [
                argument("<file>", "The file to work on."),
                argument("[rest...]", "More files."),
            ],
            options: [
                verboseOption,
                option("--name <name>", "The name to use."),
                defaultedOption("-c, --count <number>", "How many times.", "5"),
                option("-o, --opt [value]", "An option with an optional value."),
                defaultedOption("--level [level]", "An optional value with a default.", "low"),
                option("--no-color", "Turns color off."),
                defaultedOption("--no-browser", "Don't open the browser automatically", false),
                option("--flag", "A flag with a negation."),
                option("--no-flag", "The negation of the flag."),
                defaultedOption("--string-default", "A flag with a string default.", "yes"),
                option("--sk, --source-key <keyfile>", "Two long flags."),
                option("-x", "A short flag only."),
            ],
            helpTexts: [
                helpText("beforeAll", "BEFORE ALL"),
                helpText("before", "BEFORE"),
                helpText("after", "\nAFTER"),
                helpText("afterAll", "AFTER ALL"),
                helpText("after", ""),
            ],
            exitOverride: true,
            preActionHook: true,
            action: true,
        },
        cases: [
            ["a.txt"],
            ["a.txt", "b.txt", "c.txt"],
            [],
            ["-v", "a.txt"],
            ["-vc3", "a.txt"],
            ["-c", "7", "a.txt"],
            ["--count=9", "a.txt"],
            ["--count", "a.txt"],
            ["a.txt", "--count"],
            ["--name", "--verbose", "a.txt"],
            ["--opt", "a.txt"],
            ["--opt", "-v", "a.txt"],
            ["-o", "a.txt"],
            ["-ovalue", "a.txt"],
            ["--opt=", "a.txt"],
            ["--level", "--", "a.txt"],
            ["--no-color", "--no-browser", "a.txt"],
            ["--flag", "a.txt"],
            ["--no-flag", "a.txt"],
            ["--flag", "--no-flag", "a.txt"],
            ["--string-default", "a.txt"],
            ["--sk", "k1", "a.txt"],
            ["--source-key=k2", "a.txt"],
            ["-x", "a.txt"],
            ["-vx", "a.txt"],
            ["-xv", "a.txt"],
            ["-vz", "a.txt"],
            ["-", "a.txt"],
            ["--", "-v", "a.txt"],
            ["a.txt", "--", "--name"],
            ["--verbose=1", "a.txt"],
            ["--nme", "x", "a.txt"],
            ["--cont", "a.txt"],
            ["--zzzzzzzz", "a.txt"],
            ["-q", "a.txt"],
            ["a.txt", "--bogus", "--help"],
            ["--help"],
            ["-h"],
            ["a.txt", "-h", "--name"],
            ["--name", "--help"],
        ],
    },
    {
        title: "subcommands, aliases, hooks, hidden commands, required options and the help command",
        colors: false,
        program: {
            name: "psi",
            description: "The program description.",
            options: [
                parsedOption("--version", "output the version number", "record"),
                option("--debug", "Enable debug."),
                option("-q, --quiet", "Suppress optional output."),
            ],
            helpTexts: [
                helpText("beforeAll", "PROGRAM BEFORE ALL"),
                helpText("afterAll", "PROGRAM AFTER ALL"),
                helpText("after", "PROGRAM AFTER"),
            ],
            exitOverride: true,
            addHelpCommand: false,
            preActionHook: true,
            commands: [
                {
                    name: "replicate",
                    aliases: ["rep", "r"],
                    description: "Replicates a database.",
                    options: [
                        option("--db <path>", "The database."),
                        option("--dest <path>", "The destination."),
                        option("--dk, --dest-key <keyfile>", "Destination key."),
                        verboseOption,
                        option("--full", "Full replica."),
                        option("--force", "Force it."),
                    ],
                    helpTexts: [
                        helpText("after", "\nExamples:\n  psi rep --db a --dest b"),
                    ],
                    preActionHook: true,
                    action: true,
                },
                {
                    name: "add",
                    aliases: ["a"],
                    description: "Adds files.",
                    arguments: [
                        argument("[files...]", "The files to add."),
                    ],
                    options: [
                        defaultedOption("--watch", "Keep watching.", false),
                    ],
                    action: true,
                },
                {
                    name: "check",
                    description: "Checks files.",
                    arguments: [
                        argument("<files...>", "The files to check."),
                    ],
                    action: true,
                },
                {
                    name: "export",
                    description: "Exports an asset.",
                    arguments: [
                        argument("<asset-id>", "The asset."),
                        argument("<output-path>", "Where to put it."),
                    ],
                    options: [
                        defaultedOption("-t, --type <type>", "Type of asset to export.", "original"),
                    ],
                    action: true,
                },
                {
                    name: "hash-cache",
                    hidden: true,
                    description: "Hidden group.",
                    commands: [
                        {
                            name: "hash-file <file>",
                            description: "Hash a file.",
                            action: true,
                        },
                        {
                            name: "set <path> <hash> <length>",
                            description: "Record a hash.",
                            options: [
                                requiredOption("--db <path>", "The database."),
                            ],
                            action: true,
                        },
                        {
                            name: "dir",
                            description: "Print the directory.",
                            options: [
                                requiredDefaultedOption("--db <path>", "The database.", "default-db"),
                            ],
                            action: true,
                        },
                    ],
                },
                {
                    name: "debug",
                    description: "Debug commands.",
                    commands: [
                        {
                            name: "merkle-tree",
                            description: "Visualize merkle trees.",
                            options: [
                                option("--db <path>", "The database."),
                                defaultedOption("-o, --output <path>", "Output file.", "collisions.json"),
                            ],
                            action: true,
                        },
                        {
                            name: "build-sort-index",
                            description: "Rebuilds the sort index.",
                            action: true,
                        },
                    ],
                },
                {
                    name: "help [command]",
                    description: "Display help for command",
                    action: true,
                },
                {
                    name: "dbs",
                    attach: "addCommand",
                    aliases: ["d"],
                    description: "Manage the list of configured databases.",
                    commands: [
                        {
                            name: "list",
                            aliases: ["l", "ls"],
                            description: "List all configured databases.",
                            action: true,
                        },
                        {
                            name: "add",
                            description: "Add a database.",
                            options: [
                                option("--yes", "Skip prompts"),
                                option("--name <name>", "Database name"),
                            ],
                            action: true,
                        },
                    ],
                },
                {
                    name: "bug",
                    description: "Generates a bug report.",
                    options: [
                        defaultedOption("--no-browser", "Don't open the browser automatically", false),
                        parsedOption("--broken", "A parser that throws.", "throw"),
                    ],
                    action: true,
                },
            ],
        },
        cases: [
            ["replicate", "--db", "a", "--dest", "b"],
            ["rep", "--db=a", "-v"],
            ["r", "--dk", "k"],
            ["-q", "rep", "--db", "x"],
            ["rep", "-q"],
            ["--debug", "rep", "--quiet", "--db", "x"],
            ["rep", "--flul"],
            ["rep", "--bogus"],
            ["rep", "--dst", "x"],
            ["rep", "--debgu"],
            ["rep", "-z"],
            ["rep", "extra"],
            ["rep", "extra", "--bogus"],
            ["rep", "--db"],
            ["rep", "--help"],
            ["rep", "--", "x"],
            ["--version"],
            ["rep", "--version"],
            ["add"],
            ["a", "one", "two"],
            ["add", "--watch", "--", "--three"],
            ["check"],
            ["check", "one"],
            ["export", "id"],
            ["export", "id", "out", "extra"],
            ["export", "id", "out", "-t", "thumb"],
            ["export", "--help"],
            ["hash-cache", "hash-file", "f"],
            ["hash-cache", "hash-file"],
            ["hash-cache", "set", "p", "h", "l"],
            ["hash-cache", "set", "--db", "d", "p", "h", "l"],
            ["hash-cache", "set", "--db", "d", "p", "h"],
            ["hash-cache", "set", "--db", "d", "p", "h", "l", "x"],
            ["hash-cache", "dir"],
            ["hash-cache", "set", "--help"],
            ["hash-cache"],
            ["hash-cache", "--help"],
            ["hash-cache", "help", "set"],
            ["hash-cache", "nope"],
            ["debug"],
            ["debug", "--help"],
            ["debug", "help"],
            ["debug", "help", "merkle-tree"],
            ["debug", "help", "nope"],
            ["debug", "nope"],
            ["debug", "merkle-tree", "--bogus"],
            ["debug", "merkle-tree", "-o", "x"],
            ["debug", "merkle-tree", "--help"],
            ["debug", "build-sort-index", "extra"],
            ["debug", "--bogus"],
            ["help"],
            ["help", "rep"],
            ["dbs"],
            ["dbs", "--help"],
            ["d", "ls"],
            ["dbs", "add", "--nme", "x"],
            ["dbs", "add", "--name"],
            ["dbs", "help", "add"],
            ["dbs", "nope"],
            ["bug"],
            ["bug", "--no-browser"],
            ["bug", "--broken"],
            ["bug", "--help"],
            [],
            ["--help"],
            ["-h"],
            ["nope"],
            ["replicat"],
            ["ad"],
            ["hash-cach"],
            ["--bogus"],
            ["--bogus", "rep"],
            ["-qv", "rep"],
        ],
    },
    {
        title: "wrapping at a narrow width, preformatted text and wide characters",
        helpWidth: 50,
        colors: false,
        program: {
            name: "wrap",
            description: "A long description of the program that goes on and on so that it has to be wrapped at the help width.\n\nA second paragraph after a blank line.",
            arguments: [
                argument("<input>", "An argument with a description that is long enough to wrap onto more lines."),
            ],
            options: [
                option("--a-very-long-option-name-indeed <value>", "The term is wider than the others."),
                option("--short", "Short description."),
                option("--pre", "Preformatted:\n  indented line one\n  indented line two"),
                option("--unicode", "Arrows → and emoji 📷 count as JavaScript counts them, a character or two each, when wrapping."),
                option("--spaces", "Several   spaces   between   words   that   wrap   here   and   there   again."),
                option("--no-desc", ""),
            ],
            exitOverride: true,
            action: true,
        },
        cases: [
            ["--help"],
        ],
    },
    {
        title: "no wrapping below the minimum width",
        helpWidth: 30,
        colors: false,
        program: {
            name: "narrow",
            description: "A description that would wrap if the help width were not below the minimum width to wrap.",
            options: [
                option("--option", "An option description that is not wrapped either, however long it gets."),
            ],
            exitOverride: true,
            action: true,
        },
        cases: [
            ["--help"],
        ],
    },
    {
        title: "colors kept when the output shows them",
        colors: true,
        program: {
            name: "colorful",
            description: "\u001b[1mBold\u001b[22m description.",
            options: [
                option("--paint", "Some \u001b[31mred\u001b[39m text in a description long enough to wrap at eighty columns of help."),
            ],
            helpTexts: [
                helpText("after", "\u001b[1mpsi --help\u001b[22m    Shows help."),
            ],
            exitOverride: true,
            action: true,
        },
        cases: [
            ["--help"],
        ],
    },
    {
        title: "colors stripped when the output does not show them",
        colors: false,
        program: {
            name: "plain",
            description: "\u001b[1mBold\u001b[22m description.",
            options: [
                option("--paint", "Some \u001b[31mred\u001b[39m text in a description long enough to wrap at eighty columns of help."),
            ],
            helpTexts: [
                helpText("after", "\u001b[1mpsi --help\u001b[22m    Shows help."),
            ],
            exitOverride: true,
            action: true,
        },
        cases: [
            ["--help"],
        ],
    },
    {
        title: "options that conflict with the help flags",
        colors: false,
        program: {
            name: "conflicts",
            exitOverride: true,
            commands: [
                {
                    name: "short",
                    options: [
                        option("-h, --host <host>", "The host."),
                    ],
                    action: true,
                },
                {
                    name: "long",
                    options: [
                        option("--help", "A help option of its own."),
                    ],
                    action: true,
                },
                {
                    name: "both",
                    options: [
                        option("-h, --help", "Both help flags."),
                    ],
                    action: true,
                },
            ],
        },
        cases: [
            ["short", "-h", "x"],
            ["short", "--help"],
            ["long", "--help"],
            ["long", "-h"],
            ["both", "-h"],
            ["help", "short"],
            ["help"],
            ["--help"],
        ],
    },
    {
        title: "a program with no action and no subcommands",
        colors: false,
        program: {
            name: "",
            options: [
                option("--only", "The only option."),
            ],
            exitOverride: true,
        },
        cases: [
            [],
            ["--only"],
            ["a", "b"],
            ["--bogus"],
            ["--help"],
        ],
    },
    {
        title: "a program that does not override exit",
        colors: false,
        program: {
            name: "exits",
            commands: [
                {
                    name: "run",
                    arguments: [
                        argument("<what>", ""),
                    ],
                    action: true,
                },
            ],
        },
        cases: [
            ["run", "x"],
            ["run"],
            ["run", "--help"],
            ["nope"],
            [],
        ],
    },
];

const programResults = programs.map(definition => {
    return {
        title: definition.title,
        helpWidth: definition.helpWidth ?? null,
        colors: definition.colors,
        program: definition.program,
        cases: definition.cases.map(argv => runCase(definition, argv)),
    };
});
writeFileSync(join(fixturesDir, "programs.json"), JSON.stringify(programResults, null, 4) + "\n");

//
// Command lines of replicate and verify, run through the real CLI.
//
const psiCommandLines: string[][] = [
    ["replicate", "--help"],
    ["rep", "-h"],
    ["verify", "--help"],
    ["ver", "--db", "x", "--help"],
    ["rep", "--flul"],
    ["ver", "--bogus", "x"],
    ["ver", "extra"],
    ["rep", "-x"],
    ["-q", "rep", "--dst", "x"],
];
const psiResults = psiCommandLines.map(args => {
    const childEnv: any = {
        ...process.env,
        NO_COLOR: "1",
    };
    delete childEnv.FORCE_COLOR;
    const result = spawnSync("bun", ["run", "index.ts", ...args], {
        cwd: cliDir,
        encoding: "utf8",
        env: childEnv,
    });
    return {
        args,
        stdout: result.stdout,
        stderr: result.stderr,
        exitCode: result.status,
    };
});
writeFileSync(join(fixturesDir, "psi.json"), JSON.stringify(psiResults, null, 4) + "\n");
