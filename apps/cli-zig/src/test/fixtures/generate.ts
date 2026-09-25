//
// Generates the golden fixtures of the apps/cli-zig tests from the TypeScript implementation and its
// third-party packages (picocolors, wrap-ansi, string-width, commander, the local clack copy).
// Run from the repo root: FORCE_COLOR=1 TERM=xterm-256color bun run apps/cli-zig/src/test/fixtures/generate.ts
// The command-line cases are also checked against the real CLI (apps/cli/index.ts).
//
import { writeFileSync } from "fs";
import { join } from "path";
import { PassThrough, Writable } from "stream";
import { spawnSync } from "child_process";
import pc from "picocolors";
import wrapAnsi from "wrap-ansi";
import stringWidth from "string-width";
import { Command } from "commander";
import { formatBytes } from "../../../../cli/src/lib/format";
import { showInstallationInstructions } from "../../../../cli/src/lib/installation-instructions";
import { confirm, select, text, password, multiline, outro } from "../../../../cli/src/lib/clack/prompts";

const fixturesDir = import.meta.dir;
const cliDir = join(fixturesDir, "../../../../cli");

//
// Writes a fixture file as formatted JSON.
//
function writeFixture(name: string, data: any): void {
    writeFileSync(join(fixturesDir, name), JSON.stringify(data, null, 4) + "\n");
}

if (!pc.isColorSupported) {
    throw new Error("Run the generator with FORCE_COLOR=1 so that picocolors adds colors.");
}

//
// picocolors: the output of every style used by the CLI, and the color detection rules.
//
const styleNames = ["reset", "bold", "dim", "italic", "underline", "inverse", "hidden", "strikethrough", "red", "green", "yellow", "blue", "magenta", "cyan", "white", "gray"];
const colors: any = pc.createColors(true);
const styleInputs = [
    "text",
    "",
    "a\x1b[39mb",
    "\x1b[39m",
    "start \x1b[22m middle \x1b[22m end",
    "xx\x1b[39myy\x1b[39mzz",
    pc.createColors(true).green("inner"),
    `outer ${colors.red("inner")} outer`,
    `outer ${colors.bold("inner")} outer`,
    `outer ${colors.dim("inner")} outer`,
];
const styleCases: any[] = [];
for (const style of styleNames) {
    for (const input of styleInputs) {
        styleCases.push({ style, input, output: colors[style](input) });
    }
}
const detectionCases: any[] = [];
const detectionEnvironments = [
    { env: {}, argv: [] },
    { env: { NO_COLOR: "1" }, argv: [] },
    { env: { NO_COLOR: "" }, argv: [] },
    { env: { FORCE_COLOR: "1" }, argv: [] },
    { env: { FORCE_COLOR: "" }, argv: [] },
    { env: { FORCE_COLOR: "0" }, argv: [] },
    { env: { CI: "true" }, argv: [] },
    { env: { CI: "" }, argv: [] },
    { env: { TERM: "dumb", FORCE_COLOR: "1" }, argv: [] },
    { env: { NO_COLOR: "1", FORCE_COLOR: "1" }, argv: [] },
    { env: {}, argv: ["--color"] },
    { env: {}, argv: ["--no-color"] },
    { env: { FORCE_COLOR: "1" }, argv: ["--no-color"] },
    { env: { NO_COLOR: "1" }, argv: ["--color"] },
];
for (const detection of detectionEnvironments) {
    const env: any = { PATH: process.env.PATH, HOME: process.env.HOME };
    Object.assign(env, detection.env);
    const result = spawnSync("bun", ["-e", "process.stdout.write(String(require('picocolors').isColorSupported))", "script", ...detection.argv], { env, cwd: cliDir, encoding: "utf8" });
    detectionCases.push({ env: detection.env, argv: detection.argv, stdoutIsTTY: false, isColorSupported: result.stdout.trim() === "true" });
}
writeFixture("picocolors.json", { styleCases, detectionCases });

//
// formatBytes: binary and decimal units.
//
const byteValues = [0, 1, 100, 999, 1000, 1023, 1024, 1025, 1536, 2048, 10239, 10240, 10752, 102399, 102400, 1048575, 1048576, 1572864, 2359296, 2411724, 2306867,
    5242880, 5767168, 12582912, 13107200, 104857600, 123456789, 987654321, 1073741824, 1610612736, 1234567890, 10737418240, 107374182400,
    1099511627776, 1649267441664, 1125899906842623, 1125899906842624, 1152921504606846976, 1029, 1034, 10291, 1048576000, 1073217536, 6969, 7039];
const formatCases: any[] = [];
for (const bytes of byteValues) {
    formatCases.push({ bytes, binary: true, decimals: 2, output: formatBytes(bytes) });
    formatCases.push({ bytes, binary: false, decimals: 2, output: formatBytes(bytes, { binary: false }) });
    formatCases.push({ bytes, binary: true, decimals: 3, output: formatBytes(bytes, { decimals: 3 }) });
}
writeFixture("format.json", formatCases);

//
// toFixed(2) of durations in seconds (the file logger footer).
//
const durations = [0, 1, 5, 15, 125, 1005, 1125, 1234, 1235, 2675, 99999, 123456789];
writeFixture("to-fixed.json", durations.map(duration => ({ milliseconds: duration, output: (duration / 1000).toFixed(2) })));

//
// wrap-ansi and string-width.
//
const wrapStrings = [
    "hello world foo bar",
    "aaaaaaaaaaaaaaaaaaaaaa",
    "\x1b[36mcyan text that wraps around\x1b[39m",
    "\x1b[1mbold\x1b[22m and \x1b[2mdim\x1b[22m words here",
    "line one\nline two is longer than the columns",
    "a  b   c    ",
    "  leading spaces here",
    "中文字符测试中文字符测试",
    "📁 Use current directory with emoji 📂 folders",
    "word \x1b[32mgreenwordthatislong\x1b[39m end",
    "\x1b[90m \x1b[39m\n\x1b[36m*\x1b[39m  Do you want to proceed with replication?\n   This will cause the destination database to be updated to match the source database.",
    "crlf\r\nline",
    "",
    " ",
    "exactlyten exactlyten",
];
const wrapCases: any[] = [];
for (const input of wrapStrings) {
    for (const columns of [1, 5, 10, 20, 80]) {
        wrapCases.push({ input, columns, output: wrapAnsi(input, columns, { hard: true, trim: false }) });
    }
}
const widthStrings = ["", "abc", "\x1b[31mred\x1b[39m", "中文", "📁 x", "⚠️ warn", "✓", "●", "▪", "é", "á", "🇺🇸", "👍🏽", "👨‍👩‍👧", "\t", "\x1b]8;;http://x\x07link\x1b]8;;\x07", "…", "█"];
writeFixture("wrap-ansi.json", { wrapCases, widthCases: widthStrings.map(input => ({ input, width: stringWidth(input) })) });

//
// installation instructions (Linux).
//
const installationCases: any[] = [];
for (const missingTools of [["ImageMagick"], ["ffmpeg"], ["ffprobe"], ["ImageMagick", "ffprobe", "ffmpeg"], []]) {
    const lines: string[] = [];
    const originalLog = console.log;
    console.log = (message: string) => { lines.push(message); };
    showInstallationInstructions(missingTools);
    console.log = originalLog;
    installationCases.push({ missingTools, output: lines.join("\n") + "\n" });
}
writeFixture("installation-instructions.json", installationCases);

//
// Command line parsing of replicate and verify (the same declarations as apps/cli/index.ts).
//
const dbOption: [string, string] = ["--db <path>", "The directory that contains the media file database"];
const destDbOption: [string, string] = ["--dest <path>", "The destination directory that specifies the target database"];
const keyOption: [string, string] = ["-k, --key <keyfile>", "Path to the private key file for encryption."];
const destKeyOption: [string, string] = ["--dk, --dest-key <keyfile>", "Path to destination encryption key file"];
const generateKeyOption: [string, string, boolean] = ["-g, --generate-key", "Generate encryption keys if they don't exist.", false];
const verboseOption: [string, string, boolean] = ["-v, --verbose", "Enables verbose logging.", false];
const toolsOption: [string, string, boolean] = ["--tools", "Enables output from media processing tools (ImageMagick, ffmpeg, etc.).", false];
const yesOption: [string, string, boolean] = ["-y, --yes", "Non-interactive mode. Use command line arguments and defaults.", false];
const cwdOption: [string, string] = ["--cwd <path>", "Set the current working directory for directory selection prompts. Defaults to the current directory from your shell/terminal. This is mostly for testing/debugging."];
const workersOption: [string, string] = ["--workers <number>", "Number of worker threads to use for parallel processing (default: number of CPU cores)"];
const timeoutOption: [string, string] = ["--timeout <ms>", "Task timeout in milliseconds (default: 600000 = 10 minutes)"];

//
// Parses a command line with commander and returns what happened.
//
function parseWithCommander(args: string[]): any {
    let outcome: any = undefined;
    let errorOutput = "";
    // Which command reported the error: the program (no replicate or verify command was reached, so the
    // Zig CLI hands the command line to the TypeScript CLI) or the replicate or verify command.
    let errorLevel = "program";
    const program = new Command();
    program
        .name("psi")
        .option("--version", "output the version number", () => {
            outcome = { kind: "version" };
            throw new Error("version");
        })
        .option("--debug", "Enable debug REST API server")
        .option("-q, --quiet", "Suppress optional output (update and news notifications). Give it before the command name.")
        .exitOverride()
        .configureOutput({ writeErr: (message: string) => { errorOutput += message; }, writeOut: () => {} })
        .addHelpCommand(false)
        .hook("preSubcommand", () => { errorLevel = "command"; });
    program
        .command("replicate")
        .alias("rep")
        .option(...dbOption)
        .option(...destDbOption)
        .option(...keyOption)
        .option(...destKeyOption)
        .option(...generateKeyOption)
        .option("-p, --path <path>", "Replicate only files matching this path (file or directory)")
        .option("--partial", "Create a partial replica: copy only metadata and structure; asset files are fetched on demand from origin.")
        .option("--full", "Create a full replica: copy all original, display, and thumbnail files (default when --yes is used).")
        .option("--force", "Proceed with replication without confirmation, even if destination database exists, and allow replication between databases with different IDs (THIS IS DANGEROUS, use it carefully, use it rarely)")
        .option(...verboseOption)
        .option(...toolsOption)
        .option(...yesOption)
        .option(...cwdOption)
        .exitOverride()
        .configureOutput({ writeErr: (message: string) => { errorOutput += message; }, writeOut: () => {} })
        .action((options: any) => { outcome = { kind: "replicate", options, quiet: program.opts().quiet === true }; });
    program
        .command("verify")
        .alias("ver")
        .option(...dbOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...toolsOption)
        .option(...yesOption)
        .option("--full", "Force full verification (bypass cached hash optimization)", false)
        .option("-p, --path <path>", "Verify only files matching this path (file or directory)")
        .option(...workersOption)
        .option(...timeoutOption)
        .option(...cwdOption)
        .exitOverride()
        .configureOutput({ writeErr: (message: string) => { errorOutput += message; }, writeOut: () => {} })
        .action((options: any) => { outcome = { kind: "verify", options, quiet: program.opts().quiet === true }; });
    program.command("summary").action(() => { outcome = { kind: "other" }; });
    try {
        program.parse(["bun", "index.ts", ...args]);
    }
    catch (error: any) {
        if (outcome !== undefined) {
            return outcome;
        }
        if (error.code === "commander.helpDisplayed" || error.code === "commander.help") {
            return { kind: "help" };
        }
        return { kind: "error", stderr: errorOutput, code: error.code, level: errorLevel };
    }
    return outcome ?? { kind: "none" };
}

const commandLines: string[][] = [
    ["replicate", "--db", "a", "--dest", "b", "--yes"],
    ["rep", "--db=a", "--dest=b", "-y"],
    ["rep", "-k", "key1", "--dk", "key2", "-g", "-p", "sub/dir", "--partial", "--force", "-v", "--tools", "--cwd", "/tmp"],
    ["rep", "--dest-key=k2", "--key=k1", "--full"],
    ["rep", "-kmykey", "-vy"],
    ["rep", "-vyg"],
    ["rep", "-yk", "key"],
    ["rep", "--db", "a", "--db", "b"],
    ["rep", "--debug", "--db", "x"],
    ["--debug", "rep", "--db", "x"],
    ["rep", "--db", "--help"],
    ["rep", "--db", "-y"],
    ["rep", "--dk=abc", "--path=p"],
    ["rep", "--db", ""],
    ["verify", "--db", "a", "--full", "-p", "x", "--workers", "4", "--timeout", "1000", "--cwd", "c"],
    ["ver", "-vy", "--tools"],
    ["ver"],
    ["ver", "-p", "-v"],
    ["ver", "--timeout=5", "--workers=2"],
    ["rep", "--bogus"],
    ["rep", "--flul"],
    ["ver", "--ful"],
    ["rep", "--pat"],
    ["rep", "--paht", "x"],
    ["rep", "--verbos"],
    ["rep", "--dest-ke", "x"],
    ["rep", "--dst", "x"],
    ["rep", "--debgu"],
    ["rep", "--versio"],
    ["rep", "extra"],
    ["rep", "--db", "a", "extra", "more"],
    ["rep", "extra", "--bogus"],
    ["rep", "--db"],
    ["ver", "-k"],
    ["ver", "--workers"],
    ["rep", "-x"],
    ["rep", "-vx"],
    ["rep", "-y=foo"],
    ["rep", "--yes=true"],
    ["rep", "--", "x"],
    ["rep", "--db", "a", "--", "--b"],
    ["rep", "--help=x"],
    ["rep", "--full=1"],
    ["rep", "--help"],
    ["rep", "-h"],
    ["ver", "--bogus", "--help"],
    ["rep", "--help", "--db"],
    ["ver", "--version"],
    ["rep", "--db", "--version"],
    ["--version"],
    ["-q", "rep", "--db", "x"],
    ["--quiet", "ver"],
    ["ver", "-q"],
    ["rep", "--db", "x", "--quiet"],
    ["ver", "-qv"],
    ["ver", "-vq"],
    ["-qv", "ver"],
    ["rep", "--quite"],
    ["rep", "--quiet=1"],
];
const commandCases: any[] = [];
for (const args of commandLines) {
    const outcome = parseWithCommander(args);
    if (outcome.kind === "error") {
        // Check the error against the real CLI.
        const childEnv: any = { ...process.env };
        delete childEnv.FORCE_COLOR;
        const result = spawnSync("bun", ["run", "index.ts", ...args], { cwd: cliDir, encoding: "utf8", env: childEnv });
        // index.ts exits quietly for these codes; other commander errors are rethrown and reported by handleError.
        const quietCodes = ["commander.missingArgument", "commander.unknownOption", "commander.unknownCommand", "commander.excessArguments"];
        const matches = quietCodes.includes(outcome.code) ? result.stderr === outcome.stderr : result.stderr.startsWith(outcome.stderr);
        if (!matches || result.status !== 1) {
            throw new Error(`The real CLI disagrees for ${JSON.stringify(args)}: ${JSON.stringify(result.stderr)} (exit ${result.status}) vs ${JSON.stringify(outcome.stderr)}`);
        }
    }
    commandCases.push({ args, outcome });
}
writeFixture("command-line.json", commandCases);

//
// Prompts driven through fake streams, one key per chunk.
//
async function runPrompt(keys: string[], make: (input: any, output: any) => Promise<any>): Promise<any> {
    const input = new PassThrough();
    let output = "";
    const writable = new Writable({ write(chunk, encoding, callback) { output += chunk.toString(); callback(); } });
    const promise = make(input, writable);
    for (const key of keys) {
        await new Promise(resolve => setTimeout(resolve, 5));
        input.write(key);
    }
    // A prompt that is still waiting for input after the keys (e.g. a failed validation) is recorded as pending.
    const pending = Symbol("pending");
    const result = await Promise.race([promise, new Promise(resolve => setTimeout(() => resolve(pending), 200))]);
    if (result === pending) {
        return { pending: true, cancelled: false, value: null, output };
    }
    return { pending: false, cancelled: typeof result === "symbol", value: typeof result === "symbol" ? null : result, output };
}

//
// Validation used by the text and password cases.
//
function requireValue(value: string | undefined): string | undefined {
    if (!value || value.trim() === "") {
        return "Value is required";
    }
    return undefined;
}

const promptCases: any[] = [];
const confirmKeys = [["\r"], ["n"], ["y"], ["Y"], ["\x1b[C", "\r"], ["\x1b[C", "\x1b[D", "\r"], ["h", "\r"], [" ", "\r"], ["\x03"], ["\x1b[C", "\x03"], ["x", "\r"]];
for (const keys of confirmKeys) {
    promptCases.push({ prompt: "confirm", options: { message: "Continue?" }, keys, ...(await runPrompt(keys, (input, output) => confirm({ message: "Continue?", input, output }))) });
    promptCases.push({ prompt: "confirm", options: { message: "Proceed?\n   Second line.", initialValue: false, active: "Sure", inactive: "Nope" }, keys, ...(await runPrompt(keys, (input, output) => confirm({ message: "Proceed?\n   Second line.", initialValue: false, active: "Sure", inactive: "Nope", input, output }))) });
}
const selectOptions = [
    { value: "full", label: "Full", hint: "Copy everything" },
    { value: "partial", label: "Partial", hint: "Copy only metadata" },
    { value: "none" },
];
const manyOptions = Array.from({ length: 12 }, (_, index) => ({ value: `option-${index}`, label: `Option ${index}` }));
const selectKeys = [["\r"], ["\x1b[B", "\r"], ["\x1b[A", "\r"], ["j", "j", "\r"], ["k", "\r"], ["\x1b[B", "\x03"], ["y", "\r"]];
for (const keys of selectKeys) {
    promptCases.push({ prompt: "select", options: { message: "Pick one:", options: selectOptions }, keys, ...(await runPrompt(keys, (input, output) => select({ message: "Pick one:", options: selectOptions, input, output }))) });
    promptCases.push({ prompt: "select", options: { message: "Pick one:", options: selectOptions, initialValue: "partial" }, keys, ...(await runPrompt(keys, (input, output) => select({ message: "Pick one:", options: selectOptions, initialValue: "partial", input, output }))) });
}
for (const keys of [["\x1b[B", "\x1b[B", "\x1b[B", "\x1b[B", "\x1b[B", "\x1b[B", "\x1b[B", "\r"], ["\x1b[A", "\x1b[A", "\r"]]) {
    promptCases.push({ prompt: "select", options: { message: "Many:", options: manyOptions }, keys, ...(await runPrompt(keys, (input, output) => select({ message: "Many:", options: manyOptions, input, output }))) });
}
const textKeys = [["a", "b", "\x7f", "c", "\r"], ["\r"], ["\r", "x", "\r"], ["a", "\x1b[D", "b", "\r"], ["a", "\x03"], ["\x03"], ["a", "b", "\x1b[D", "\x1b[D", "\x1b[3~", "\r"], ["a", "\t", "b", "\r"], ["h", "e", "y", "\x15", "o", "k", "\r"], ["w", "o", "r", "d", " ", "t", "w", "o", "\x17", "\r"]];
for (const keys of textKeys) {
    promptCases.push({ prompt: "text", options: { message: "Name:", placeholder: "my-photos" }, keys, ...(await runPrompt(keys, (input, output) => text({ message: "Name:", placeholder: "my-photos", input, output }))) });
    promptCases.push({ prompt: "text", options: { message: "Name:", defaultValue: "fallback", validate: "required" }, keys, ...(await runPrompt(keys, (input, output) => text({ message: "Name:", defaultValue: "fallback", validate: requireValue, input, output }))) });
    promptCases.push({ prompt: "text", options: { message: "Key name:", initialValue: "my-photos", placeholder: "my-photos" }, keys, ...(await runPrompt(keys, (input, output) => text({ message: "Key name:", initialValue: "my-photos", placeholder: "my-photos", input, output }))) });
}
const passwordKeys = [["s", "e", "c", "\r"], ["\r", "k", "\r"], ["a", "b", "\x03"], ["a", "b", "\x1b[D", "\r"]];
for (const keys of passwordKeys) {
    promptCases.push({ prompt: "password", options: { message: "Secret:", validate: "required" }, keys, ...(await runPrompt(keys, (input, output) => password({ message: "Secret:", validate: requireValue, input, output }))) });
}
const multilineKeys = [["l", "1", "\r", "l", "2", "\x04"], ["x", "\x03"], ["a", "\r", "\x7f", "b", "\x04"], ["\x04"]];
for (const keys of multilineKeys) {
    promptCases.push({ prompt: "multiline", options: { message: "Paste:" }, keys, ...(await runPrompt(keys, (input, output) => multiline({ message: "Paste:", input, output }))) });
}
{
    let output = "";
    const writable = new Writable({ write(chunk, encoding, callback) { output += chunk.toString(); callback(); } });
    outro(pc.red("Done"), { output: writable });
    promptCases.push({ prompt: "outro", options: { message: pc.red("Done") }, keys: [], pending: false, cancelled: false, value: null, output });
}
writeFixture("prompts.json", promptCases);

console.log("Fixtures written.");
process.exit(0);
