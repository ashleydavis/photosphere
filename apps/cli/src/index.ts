import { program } from 'commander';
import { uiCommand } from './cmd/ui';
import { addCommand } from './cmd/add';
import { checkCommand } from './cmd/check';
import { initCommand } from './cmd/init';
import { configureCommand } from './cmd/config';
import { infoCommand } from './cmd/info';
import { toolsCommand } from './cmd/tools';
import { summaryCommand } from './cmd/summary';
import { verifyCommand } from './cmd/verify';
import { replicateCommand } from './cmd/replicate';
import { compareCommand } from './cmd/compare';
import { merkleTreeCommand } from './cmd/merkle-tree';
import { hashCacheCommand } from './cmd/hash-cache';
import { jsonCommand } from './cmd/json';
import { bugReportCommand } from './cmd/bug';
import { examplesCommand } from './cmd/examples';
import { versionCommand } from './cmd/version';
import { listCommand } from './cmd/list';
import { exportCommand } from './cmd/export';
import { upgradeCommand } from './cmd/upgrade';
import { repairCommand } from './cmd/repair';
import { removeCommand } from './cmd/remove';
import { rootHashCommand } from './cmd/root-hash';
import { clearCacheCommand } from './cmd/clear-cache';
import { debugHashCommand } from './cmd/debug-hash';
import { debugSyncCommand } from './cmd/debug-sync';
import { 
    debugShowCollectionsCommand,
    debugShowShardsCommand, 
    debugShowShardCommand, 
    debugShowRecordCommand, 
    debugShowSortIndexesCommand, 
    debugShowSortIndexCommand, 
    debugShowSortIndexPageCommand 
} from './cmd/debug-show';
import { MAIN_EXAMPLES, getCommandExamplesHelp } from './examples';
import pc from "picocolors";
import { exit } from 'node-utils';
import { log } from 'utils';
import { version } from './lib/version';

async function main() {

    const dbOption: [string, string] = ["--db <path>", "The directory that contains the media file database"];
    const destDbOption: [string, string] = ["--dest <path>", "The destination directory that specifies the target database"];
    const sourceDbOption: [string, string] = ["--source <path>", "The source directory that contains the database to repair from"];
    const metadataDirOption: [string, string] = ["-m, --meta <db-metadata-dir>", `The directory in which to store asset database metadata. (default: "<current-dir>/.db")`];
    const keyOption: [string, string] = ["-k, --key <keyfile>", "Path to the private key file for encryption."];
    const generateKeyOption: [string, string, boolean] = ["-g, --generate-key", "Generate encryption keys if they don't exist.", false];
    const verboseOption: [string, string, boolean] = ["-v, --verbose", "Enables verbose logging.", false];
    const toolsOption: [string, string, boolean] = ["--tools", "Enables output from media processing tools (ImageMagick, ffmpeg, etc.).", false];
    const yesOption: [string, string, boolean] = ["-y, --yes", "Non-interactive mode. Use command line arguments and defaults.", false];
    const cwdOption: [string, string] = ["--cwd <path>", "Set the current working directory for directory selection prompts. Defaults to the current directory from your shell/terminal. This is mostly for testing/debugging."];
    const sessionIdOption: [string, string] = ["--session-id <id>", "Set session identifier for write lock tracking. Defaults to a random UUID."];

    program
        .name("psi")
        .description(`The Photosphere CLI tool for managing your media file database.`)
        .option('--version', 'output the version number', () => {
            console.log(version);
            process.exit(0);
        })
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
        .exitOverride();  // Prevent commander from calling process.exit

    program
        .command("add")
        .alias("a")
        .description("Adds files and directories to the media file database.")
        .argument("<files...>", "The media files (or directories) to add to the database.")
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...toolsOption)
        .option(...yesOption)
        .option(...cwdOption)
        .option(...sessionIdOption)
        .addHelpText('after', getCommandExamplesHelp('add'))
        .action(addCommand);

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
        .description("Checks files and direcotires to see what has already been added to the media file database.")
        .argument("<files...>", "The media files (or directories) to add to the database.")
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...toolsOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('check'))
        .action(checkCommand);

    program
        .command("compare")
        .alias("cmp")
        .description("Compares two asset databases by analyzing their Merkle trees.")
        .option(...dbOption)
        .option(...destDbOption)
        .option("-s, --src-meta <dir>", "Source metadata directory override")
        .option("-d, --dest-meta <dir>", "Destination metadata directory override")
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('compare'))
        .action(compareCommand);

    program
        .command("config")
        .alias("cfg")
        .description("Interactive configuration wizard for S3 credentials and Google API key.")
        .option("-c, --clear", "Clear all configuration files")
        .addHelpText('after', getCommandExamplesHelp('config'))
        .action(configureCommand);

    // Add debug commands with shared options
    const debugCommand = program
        .command('debug')
        .description('Debug utilities for inspecting the media file database internals');

    // Add merkle-tree subcommand
    debugCommand
        .command('merkle-tree')
        .description('Visualize the merkle tree structure of the media file database')
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .option('-s, --simple', 'Use simple visualization format')
        .addHelpText('after', getCommandExamplesHelp('debug merkle-tree'))
        .action(merkleTreeCommand);

    // Add hash-cache subcommand
    debugCommand
        .command('hash-cache')
        .description('Display information about the local and database hash caches')
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option('-t, --type <type>', 'Cache type to display: \'local\', \'database\', or \'both\' (default: \'both\')')
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('debug hash-cache'))
        .action(hashCacheCommand);

    // Add root-hash subcommand
    debugCommand
        .command('root-hash')
        .description('Print the root hash of the media file database')
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .action(rootHashCommand);

    // Add clear-cache subcommand
    debugCommand
        .command('clear-cache')
        .description('Clear the local and/or database hash caches')
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('debug clear-cache'))
        .action(clearCacheCommand);

    // Add json subcommand
    debugCommand
        .command('json')
        .description('Serialize the merkle tree to JSON format')
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('debug json'))
        .action(jsonCommand);

    // Add hash subcommand
    debugCommand
        .command('hash')
        .description('Hash a file through the storage abstraction')
        .argument('<file-path>', 'The file path to hash (supports fs:, s3:, and encrypted storage)')
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('debug hash'))
        .action(debugHashCommand);

    debugCommand
        .command('sync')
        .description('Synchronize the local database with a remote/shared database')
        .option(...dbOption)
        .option(...destDbOption)
        .option(...metadataDirOption)
        .option("-d, --dest-meta <dir>", "Destination metadata directory override")
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('debug sync'))
        .action(debugSyncCommand);

    // Add collections subcommand
    debugCommand
        .command('collections')
        .description('Lists the collections in the BSON database')
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .action(debugShowCollectionsCommand);

    // Add shards subcommand
    debugCommand
        .command('shards')
        .description('Lists the shards in the BSON database')
        .argument('<collection-name>', 'The name of the collection to examine')
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .action(debugShowShardsCommand);

    // Add shard subcommand
    debugCommand
        .command('shard')
        .description('Deserializes and prints one shard')
        .argument('<collection-name>', 'The name of the collection to examine')
        .argument('<shard-id>', 'The ID of the shard to show')
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .option('--all', 'Display all object fields (no truncation)')
        .option('--records', 'Only show record IDs, not full record data')
        .action(debugShowShardCommand);

    // Add record subcommand
    debugCommand
        .command('record')
        .description('Deserialize and show one record')
        .argument('<collection-name>', 'The name of the collection to examine')
        .argument('<record-id>', 'The ID of the record to show')
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .option('--all', 'Display all object fields (no truncation)')
        .action(debugShowRecordCommand);

    // Add sort-indexes subcommand
    debugCommand
        .command('sort-indexes')
        .description('Show a list of sort indexes')
        .argument('<collection-name>', 'The name of the collection to examine')
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .action(debugShowSortIndexesCommand);

    // Add sort-index subcommand
    debugCommand
        .command('sort-index')
        .description('Visualize the structure of a specific sort index')
        .argument('<collection-name>', 'The name of the collection to examine')
        .argument('<field-name>', 'The field name of the sort index')
        .argument('<direction>', 'The direction of the sort index (asc or desc)')
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .action(debugShowSortIndexCommand);

    // Add sort-index-page subcommand
    debugCommand
        .command('sort-index-page')
        .description('Deserialize and show one sort index page')
        .argument('<collection-name>', 'The name of the collection to examine')
        .argument('<field-name>', 'The field name of the sort index')
        .argument('<direction>', 'The direction of the sort index (asc or desc)')
        .argument('<page-id>', 'The ID of the page to show')
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .action(debugShowSortIndexPageCommand);

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
        .option(...metadataDirOption)
        .option(...keyOption)
        .option("-t, --type <type>", "Type of asset to export: original, display, or thumb (default: original)", "original")
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('export'))
        .action(exportCommand);

    program
        .command("info")
        .alias("inf")
        .description("Displays detailed information about media files including EXIF data, metadata, and technical specifications.")
        .option(...verboseOption)
        .option(...toolsOption)
        .option(...yesOption)
        .argument("<files...>", "The media files to analyze.")
        .addHelpText('after', getCommandExamplesHelp('info'))
        .action(infoCommand);

    program
        .command("init")
        .alias("i")
        .description("Initializes a new media file database.")
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...generateKeyOption)
        .option(...verboseOption)
        .option(...toolsOption)
        .option(...yesOption)
        .option(...cwdOption)
        .option(...sessionIdOption)
        .addHelpText('after', getCommandExamplesHelp('init'))
        .action(initCommand);

    program
        .command("list")
        .alias("ls")
        .description("Lists all files in the database sorted by date (newest first) with pagination.")
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .option("--page-size <size>", "Number of files to display per page (default: 20)", "20")
        .addHelpText('after', getCommandExamplesHelp('list'))
        .action(listCommand);

    program
        .command("remove")
        .alias("rm")
        .description("Removes an asset from the database by ID, marking it as deleted in the merkle tree.")
        .argument("<asset-id>", "The ID of the asset to remove.")
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('remove'))
        .action(removeCommand);

    program
        .command("repair")
        .description("Repairs the integrity of the media file database by restoring files from a source database.")
        .option(...dbOption)
        .option(...sourceDbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option("-s, --source-meta <dir>", "Source metadata directory override")
        .option("--sk, --source-key <keyfile>", "Path to source encryption key file")
        .option(...verboseOption)
        .option(...yesOption)
        .option("--full", "Force full verification (bypass cached hash optimization)", false)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('repair'))
        .action(repairCommand);

    program
        .command("replicate")
        .alias("rep")
        .description("Replicates an asset database from source to destination location.")
        .option(...dbOption)
        .option(...destDbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option("-d, --dest-meta <dir>", "Destination metadata directory override")
        .option("--dk, --dest-key <keyfile>", "Path to destination encryption key file")
        .option(...generateKeyOption)
        .option("-p, --path <path>", "Replicate only files matching this path (file or directory)")
        .option(...verboseOption)
        .option(...toolsOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('replicate'))
        .action(replicateCommand);

    program
        .command("summary")
        .alias("sum")
        .description("Displays a summary of the media file database including total files, size, and tree hash.")
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('summary'))
        .action(summaryCommand);

    program
        .command("tools")
        .description("Checks for required media processing tools (ImageMagick, ffmpeg, ffprobe).")
        .option(...yesOption)
        .addHelpText('after', getCommandExamplesHelp('tools'))
        .action(toolsCommand);

    program
        .command("ui")
        .description("Starts the Photosphere user-interface to view, search and edit photos and videos.")
        .option(...dbOption)
        .option(...keyOption)
        .option(...metadataDirOption)
        .option("--no-open", "Disables opening the UI in the default browser.", false)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('ui'))
        .action(uiCommand);

    program
        .command("upgrade")
        .description("Upgrades a media file database to the latest format by adding missing metadata files.")
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('upgrade'))
        .action(upgradeCommand);

    program
        .command("verify")
        .alias("ver")
        .description("Verifies the integrity of the media file database by checking file hashes.")
        .option(...dbOption)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...toolsOption)
        .option(...yesOption)
        .option("--full", "Force full verification (bypass cached hash optimization)", false)
        .option("-p, --path <path>", "Verify only files matching this path (file or directory)")
        .option(...cwdOption)
        .addHelpText('after', getCommandExamplesHelp('verify'))
        .action(verifyCommand);

    program
        .command("version")
        .description("Displays version information for psi and its dependencies.")
        .addHelpText('after', getCommandExamplesHelp('version'))
        .action(versionCommand);

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
function handleError(error: any) {
    log.error(pc.red('An error occurred:'));
    if (error.message) {
        log.error(pc.red(error.message).toString());
    }
    if (error.stack) {
        log.error((pc.red(error.stack).toString()));
    }
    else {
        log.error(pc.red(error.toString()).toString());
    }

    console.log('');
    console.log('If you believe this behaviour is a bug, please report it with the following command:');
    console.log(pc.yellow('   psi bug'));
}

// Handle unhandled errors
process.on('uncaughtException', (error) => {
    handleError(error);
    process.exit(1);
});

// Handle unhandled promise rejections
process.on('unhandledRejection', (reason, promise) => {
    handleError(reason);
    process.exit(1);
});

main()
    .catch(async (error) => {
        handleError(error);
        return exit(1);
    });