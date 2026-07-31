//
// The config file used when none is named on the command line, resolved against the working
// directory.
//
const DEFAULT_CONFIG_PATH = "what-changed.json";

//
// What the command line asked for.
//
export interface CliOptions {
    //
    // The gate config file to read.
    //
    configPath: string;

    //
    // Run every eligible target regardless of whether anything changed.
    //
    force: boolean;

    //
    // Report the decision and exit without running anything.
    //
    planOnly: boolean;

    //
    // List the files that differ from the last passing run, with their hashes, and exit without
    // running anything.
    //
    filesOnly: boolean;

    //
    // Record the current tree as the baseline without running anything, as if the tests had just
    // passed.
    //
    baselineOnly: boolean;

    //
    // Print the usage text and exit without running anything.
    //
    showHelp: boolean;

    //
    // The targets to consider. Empty means every target in the config.
    //
    targetNames: string[];
}

//
// Parses the command line, throwing an error on anything it does not recognise. Separated from the
// entry point so the argument rules can be tested on their own.
//
export function parseCliArgs(argv: string[]): CliOptions {
    const options: CliOptions = {
        configPath: DEFAULT_CONFIG_PATH,
        force: false,
        planOnly: false,
        filesOnly: false,
        baselineOnly: false,
        showHelp: false,
        targetNames: [],
    };

    for (let argIndex = 0; argIndex < argv.length; argIndex++) {
        const argument = argv[argIndex];
        if (argument === "--") {
            //
            // Ignored rather than rejected. A package runner such as `bun run` or `npm run` only
            // strips a "--" that comes before the first positional argument, so an invocation like
            // "bun run check compile -- --plan" forwards a bare one straight through to here.
            //
            continue;
        }
        if (argument === "--force") {
            options.force = true;
        }
        else if (argument === "--plan") {
            options.planOnly = true;
        }
        else if (argument === "--files") {
            options.filesOnly = true;
        }
        else if (argument === "--baseline") {
            options.baselineOnly = true;
        }
        else if (argument === "--help") {
            options.showHelp = true;
        }
        else if (argument === "--config") {
            const value = argv[argIndex + 1];
            if (value === undefined || value.startsWith("--")) {
                throw new Error(`The "--config" option needs a path after it.`);
            }
            options.configPath = value;
            argIndex += 1;
        }
        else if (argument.startsWith("-")) {
            throw new Error(`Unknown option "${argument}". Run with --help to see the options.`);
        }
        else {
            options.targetNames.push(argument);
        }
    }

    return options;
}

//
// The usage text, kept here so the entry point holds no prose.
//
export function helpText(): string {
    return [
        "Usage: what-changed [options] [target names]",
        "",
        "Runs the project's test scripts, but only the ones whose watched paths have changed since",
        "they last passed. With no target names it considers every target in the config.",
        "",
        "Options:",
        "  --force           Run every eligible target even if nothing changed.",
        "  --plan            Print what would run and exit without running anything.",
        "  --files           List the files that changed since the last passing run, with their",
        "                    hashes, and exit without running anything.",
        "  --baseline        Record the current tree as the baseline, as if the tests had just",
        "                    passed, without running anything. --plan wins if both are given.",
        "  --config <path>   The gate config file to read (default: what-changed.json).",
        "  --help            Print this text.",
    ].join("\n");
}
