import { program } from 'commander';
import { addCommand } from './src/cmd/add';
import { checkCommand } from './src/cmd/check';
import { initCommand } from './src/cmd/init';
import { configureCommand } from './src/cmd/config';
import { infoCommand } from './src/cmd/info';
import { toolsCommand } from './src/cmd/tools';
import { summaryCommand } from './src/cmd/summary';
import { verifyCommand } from './src/cmd/verify';
import { replicateCommand } from './src/cmd/replicate';
import { compareCommand } from './src/cmd/compare';
import { hashCacheCommand } from './src/cmd/hash-cache';
import { debugMerkleTreeCommand, debugFindCollisionsCommand, debugFindDuplicatesCommand, debugRemoveDuplicatesCommand, debugBuildSortIndexCommand } from './src/cmd/debug';
import { bugReportCommand } from './src/cmd/bug';
import { examplesCommand } from './src/cmd/examples';
import { versionCommand } from './src/cmd/version';
import { listCommand } from './src/cmd/list';
import { exportCommand } from './src/cmd/export';
import { findOrphansCommand } from './src/cmd/find-orphans';
import { upgradeCommand } from './src/cmd/upgrade';
import { repairCommand } from './src/cmd/repair';
import { removeCommand } from './src/cmd/remove';
import { removeOrphansCommand } from './src/cmd/remove-orphans';
import { clearCacheCommand } from './src/cmd/clear-cache';
import { hashCommand } from './src/cmd/hash';
import { rootHashCommand } from './src/cmd/root-hash';
import { databaseIdCommand } from './src/cmd/database-id';
import { syncCommand } from './src/cmd/sync';
import { initContext } from './src/lib/init-cmd';
import { MAIN_EXAMPLES, getCommandExamplesHelp } from './src/examples';
import pc from "picocolors";
import { exit } from 'node-utils';
import { log, FatalError } from 'utils';
import { version } from './src/lib/version';
import { startDebugServer } from 'debug-server';

async function main() {

    const dbOption: [string, string] = ["--db <path>", "The directory that contains the media file database"];
    const destDbOption: [string, string] = ["--dest <path>", "The destination directory that specifies the target database"];
    const sourceDbOption: [string, string] = ["--source <path>", "The source directory that contains the database to repair from"];
    const keyOption: [string, string] = ["-k, --key <keyfile>", "Path to the private key file for encryption."];
    const destKeyOption: [string, string] = ["--dk, --dest-key <keyfile>", "Path to destination encryption key file"];
    const generateKeyOption: [string, string, boolean] = ["-g, --generate-key", "Generate encryption keys if they don't exist.", false];
    const verboseOption: [string, string, boolean] = ["-v, --verbose", "Enables verbose logging.", false];
    const toolsOption: [string, string, boolean] = ["--tools", "Enables output from media processing tools (ImageMagick, ffmpeg, etc.).", false];
    const yesOption: [string, string, boolean] = ["-y, --yes", "Non-interactive mode. Use command line arguments and defaults.", false];
    const cwdOption: [string, string] = ["--cwd <path>", "Set the current working directory for directory selection prompts. Defaults to the current directory from your shell/terminal. This is mostly for testing/debugging."];
    const sessionIdOption: [string, string] = ["--session-id <id>", "Set session identifier for write lock tracking. Defaults to a random UUID."];
    const recordsOption: [string, string, boolean] = ["--records", "Show JSON for each internal record in each shard.", false];
    const allOption: [string, string, boolean] = ["--all", "Show all fields and full values (don't truncate) when displaying records.", false];
    const fullOption: [string, string, boolean] = ["--full", "Show all differences without truncation.", false];
    const maxOption: [string, string] = ["--max <number>", "Maximum number of items to show in each category (default: 10)"];
    const workersOption: [string, string] = ["--workers <number>", "Number of worker threads to use for parallel processing (default: number of CPU cores)"];
    const timeoutOption: [string, string] = ["--timeout <ms>", "Task timeout in milliseconds (default: 600000 = 10 minutes)"];
    const dryRunOption: [string, string, boolean] = ["--dry-run", "Run without making any database changes (merkle tree and metadata updates are skipped)", false];

    program
        .name("psi")
        .description(`The Photosphere CLI tool for managing your media file database.`)
        .option('--version', 'output the version number', () => {
            console.log(version);
            process.exit(0);
        })
        .option('--debug', 'Enable debug REST API server')
        .addHelpText('after', `

Getting help:
  ${pc.bold("psi <command> --help")}    Shows help for a particular command.
  ${pc.bold("psi --help")}              Shows help for all commands.

Examples:
${MAIN_EXAMPLES.map(ex => `  ${ex.command.padEnd(46)} ${ex.description}`).join('\n')}

Resources:
  🚀 Getting Started: https://github.com/ashleydavis/photosphere/wiki/Getting-Started
  📖 Command Reference: https://github.com/ashleydavis/photosphere/wiki/Command-Reference
  📚 Wiki: https://github.com/ashleydavis/photosphere/wiki
  🐛 View Issues: https://github.com/ashleydavis/photosphere/issues
  ➕ New Issue: https://github.com/ashleydavis/photosphere/issues/new`)
        .exitOverride()  // Prevent commander from calling process.exit
        .addHelpCommand(false);  // Disable default help command so we can add it in alphabetical order

    program
        .command("add")
        .alias("a")
        .description("Adds files and directories to the media file database.")
        .argument("<files...>", "The media files (or directories) to add to the database.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...toolsOption)
        .option(...yesOption)
        .option(...cwdOption)
        .option(...sessionIdOption)
        .option(...dryRunOption)
        .option(...workersOption)
        .addHelpText('after', getCommandExamplesHelp('add'))
        .action(initContext(addCommand));

    program
        .command("bug")
        .description("Generates a bug report for GitHub with system information and logs.")
        .option(...verboseOption)
        .option(...yesOption)
        .option("--no-browser", "Don't open the browser automatically", false)
        .addHelpText('after', getCommandExamplesHelp('bug'))
        .action(bugReportCommand);

    program
        .command("check")
        .alias("chk")
        .description("Checks files and directories to see what has already been added to the media file database.")
        .argument("<files...>", "The media files (or directories) to add to the database.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...toolsOption)
        .option(...yesOption)
        .option(...workersOption)
        .option(...timeoutOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('check'))
        .action(initContext(checkCommand));

    program
        .command("clear-cache")
        .description("Clear the local hash cache to force re-hashing of files.")
        .action(clearCacheCommand);

    program
        .command("compare")
        .alias("cmp")
        .description("Compares two databases to find the differences between them.")
        .option(...dbOption)
        .option(...destDbOption)
        .option(...keyOption)
        .option(...destKeyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .option(...fullOption)
        .option(...maxOption)
        .addHelpText('after', getCommandExamplesHelp('compare'))
        .action(initContext(compareCommand));

    program
        .command("config")
        .alias("cfg")
        .description("Interactive configuration wizard for S3 credentials and Google API key.")
        .option("-c, --clear", "Clear all configuration files")
        .addHelpText('after', getCommandExamplesHelp('config'))
        .action(configureCommand);

    program
        .command("examples")
        .description("Shows usage examples for all CLI commands.")
        .option(...yesOption)
        .addHelpText('after', getCommandExamplesHelp('examples'))
        .action(examplesCommand);

    program
        .command("export")
        .alias("exp")
        .description("Exports an asset by ID to a specified path.")
        .argument("<asset-id>", "The ID of the asset to export.")
        .argument("<output-path>", "The path where the asset should be exported.")
        .option(...dbOption)
        .option(...keyOption)
        .option("-t, --type <type>", "Type of asset to export: original, display, or thumb (default: original)", "original")
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('export'))
        .action(initContext(exportCommand));

    program
        .command("find-orphans")
        .description("Find and list files that are no longer in the merkle tree.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('find-orphans'))
        .action(initContext(findOrphansCommand));

    program
        .command("hash")
        .description("Compute the hash of a file using the same algorithm as the database.")
        .argument("<file-path>", "The file path to hash (supports fs:, s3:, and encrypted storage)")
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('hash'))
        .action(hashCommand);

    program
        .command("hash-cache")
        .description("Display information about the local hash cache.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .action(hashCacheCommand);

    const debugCommand = program
        .command("debug")
        .description("Debug commands for inspecting database internals.");

    debugCommand
        .command("merkle-tree")
        .description("Visualize all merkle trees in a media file database.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .option(...recordsOption)
        .option(...allOption)
        .action(initContext(debugMerkleTreeCommand));

    debugCommand
        .command("find-collisions")
        .description("Finds hash collisions (same hash, different asset IDs) and writes results to JSON file.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .option("-o, --output <path>", "Output JSON file path (default: collisions.json)", "collisions.json")
        .action(initContext(debugFindCollisionsCommand));

    debugCommand
        .command("find-duplicates")
        .description("Finds duplicate assets by comparing file content. Reads collisions JSON from find-collisions.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .option("-i, --input <path>", "Input JSON file path from find-collisions command (default: collisions.json)", "collisions.json")
        .option("-o, --output <path>", "Output JSON file path (default: duplicates.json)", "duplicates.json")
        .action(initContext(debugFindDuplicatesCommand));

    debugCommand
        .command("remove-duplicates")
        .description("Removes duplicate assets based on content comparison results from find-duplicates.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .option("-i, --input <path>", "Input JSON file path from find-duplicates command (default: duplicates.json)", "duplicates.json")
        .action(initContext(debugRemoveDuplicatesCommand));

    debugCommand
        .command("build-sort-index")
        .description("Deletes all sort index files and rebuilds them completely.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .action(initContext(debugBuildSortIndexCommand));

    program
        .command("help [command]")
        .description("Display help for command")
        .action((command?: string) => {
            if (command) {
                const cmd = program.commands.find(c => c.name() === command || c.aliases().includes(command));
                if (cmd) {
                    cmd.help();
                } else {
                    console.error(`Unknown command: ${command}`);
                    program.help();
                }
            } else {
                program.help();
            }
        });

    program
        .command("info")
        .alias("inf")
        .description("Displays detailed information about media files including EXIF data, metadata, and technical specifications.")
        .option(...dbOption)
        .option(...verboseOption)
        .option(...toolsOption)
        .option(...yesOption)
        .option(...cwdOption)
        .argument("<files...>", "File path(s), asset ID(s), or hash(es). --db is required only when looking up by asset ID or hash.")
        .addHelpText('after', getCommandExamplesHelp('info'))
        .action(initContext(infoCommand));

    program
        .command("init")
        .alias("i")
        .description("Initializes a new media file database.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...generateKeyOption)
        .option(...verboseOption)
        .option(...toolsOption)
        .option(...yesOption)
        .option(...cwdOption)
        .option(...sessionIdOption)
        .addHelpText('after', getCommandExamplesHelp('init'))
        .action(initContext(initCommand));

    program
        .command("list")
        .alias("ls")
        .description("Lists all files in the database sorted by date (newest first) with pagination.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .option("--page-size <size>", "Number of files to display per page (default: 20)", "20")
        .addHelpText('after', getCommandExamplesHelp('list'))
        .action(initContext(listCommand));

    program
        .command("remove")
        .alias("rm")
        .description("Removes an asset from the database by ID, deleting the files for the asset.")
        .argument("<asset-id>", "The ID of the asset to remove.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('remove'))
        .action(initContext(removeCommand));

    program
        .command("remove-orphans")
        .description("Find and remove files that are no longer in the merkle tree.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('remove-orphans'))
        .action(initContext(removeOrphansCommand));

    program
        .command("repair")
        .description("Repairs the integrity of the media file database by restoring files from a source database.")
        .option(...dbOption)
        .option(...sourceDbOption)
        .option(...keyOption)
        .option("--sk, --source-key <keyfile>", "Path to source encryption key file")
        .option(...verboseOption)
        .option(...yesOption)
        .option("--full", "Force full verification (bypass cached hash optimization)", false)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('repair'))
        .action(initContext(repairCommand));

    program
        .command("root-hash")
        .description("Displays the aggregate root hash of the database.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .action(initContext(rootHashCommand));

    program
        .command("database-id")
        .description("Displays the database ID (UUID) of the database.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .action(initContext(databaseIdCommand));

    program
        .command("replicate")
        .alias("rep")
        .description("Replicates an asset database from source to destination location.")
        .option(...dbOption)
        .option(...destDbOption)
        .option(...keyOption)
        .option(...destKeyOption)
        .option(...generateKeyOption)
        .option("-p, --path <path>", "Replicate only files matching this path (file or directory)")
        .option("--partial", "Only copy thumb directory assets. Asset and display files will be lazily copied when needed.")
        .option("--force", "Proceed with replication without confirmation, even if destination database exists, and allow replication between databases with different IDs (THIS IS DANGEROUS, use it carefully, use it rarely)")
        .option(...verboseOption)
        .option(...toolsOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('replicate'))
        .action(initContext(replicateCommand));

    program
        .command("summary")
        .alias("sum")
        .description("Displays a summary of the media file database including total files, size, and tree hash.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('summary'))
        .action(initContext(summaryCommand));

    program
        .command("sync")
        .description("Synchronize changes between two databases.")
        .option(...dbOption)
        .option(...destDbOption)
        .option(...keyOption)
        .option(...destKeyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('sync'))
        .action(initContext(syncCommand));

    program
        .command("tools")
        .description("Checks for required media processing tools (ImageMagick, ffmpeg, ffprobe).")
        .option(...yesOption)
        .addHelpText('after', getCommandExamplesHelp('tools'))
        .action(toolsCommand);

    program
        .command("upgrade")
        .description("Upgrades a media file database to the latest version.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('upgrade'))
        .action(initContext(upgradeCommand));

    program
        .command("verify")
        .alias("ver")
        .description("Verifies the integrity of the media file database by checking file hashes.")
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
        .addHelpText('after', getCommandExamplesHelp('verify'))
        .action(initContext(verifyCommand));


    program
        .command("version")
        .description("Displays version information for psi and its dependencies.")
        .addHelpText('after', getCommandExamplesHelp('version'))
        .action(versionCommand);

    // Start debug server if --debug flag is set (before parsing so it's available during command execution)
    if (process.argv.includes('--debug')) {
        try {
            const { url } = await startDebugServer({
                initialData: {},
                openBrowser: true
            });
            console.log(pc.green(`Debug REST API server started on ${url}`));
            console.log(pc.cyan("Press Ctrl+C in this terminal to stop the server."));
        }
        catch (error: any) {
            console.error(pc.red(`Failed to start debug server: ${error.message}`));
        }
    }

    // Parse the command line arguments
    try {
        await program.parseAsync(process.argv);
    } catch (err: any) {
        // Commander throws an error when no command is provided
        // Check if this is just a help display situation
        if (err.code === 'commander.help' 
            || err.code === 'commander.helpDisplayed') {
            await exit(0);
        }
        
        if (err.code === 'commander.missingArgument' 
            || err.code === 'commander.unknownOption'
            || err.code === 'commander.unknownCommand' 
            || err.code === 'commander.excessArguments') {
            await exit(1);
        }

        // If no command was provided and we're showing help
        if (process.argv.length <= 2) {
            await exit(0);
        }

        throw err;
    }
}

//
// Handles errors in a consistent way.
//
function handleError(error: any, errorType: string | undefined) {
    if (error instanceof FatalError) {
        log.error(`\n\n${pc.red(error.message)}`);
        return;
    }

    if (errorType) {
        log.exception(`An ${errorType} error occurred`, error);    
    } 
    else {
        log.exception('An unknown error occurred', error);
    }

    console.log('');
    console.log('If you believe this behaviour is a bug, please report it with the following command:');
    console.log(pc.yellow('   psi bug'));
}

// Handle unhandled errors
process.on('uncaughtException', (error) => {
    handleError(error, 'uncaughtException');
    process.exit(1);
});

// Handle unhandled promise rejections
process.on('unhandledRejection', (reason, promise) => {
    handleError(reason, 'unhandledRejection');
    process.exit(1);
});

main()
    .catch(async (error) => {
        handleError(error, undefined);
        return exit(1);
    });