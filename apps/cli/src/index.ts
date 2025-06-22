import { program } from 'commander';
import { version } from '../package.json';
import { uiCommand } from './cmd/ui';
import { addCommand } from './cmd/add';
import { checkCommand } from './cmd/check';
import { initCommand } from './cmd/init';
import { configureCommand } from './cmd/configure';
import { infoCommand } from './cmd/info';
import { toolsCommand } from './cmd/tools';
import { summaryCommand } from './cmd/summary';
import { verifyCommand } from './cmd/verify';
import { replicateCommand } from './cmd/replicate';
import { compareCommand } from './cmd/compare';
import { createDebugCommand } from './cmd/debug';
import { bugReportCommand } from './cmd/bug-report';
import { examplesCommand } from './cmd/examples';
import { MAIN_EXAMPLES, getCommandExamplesHelp } from './examples';
import pc from "picocolors";
import { exit } from 'node-utils';

async function main() {

    const dbArgument: [string, string] = ["[database-dir]", `The directory that contains the media file database. Defaults to the current directory.`];
    const metadataDirOption: [string, string] = ["-m, --meta <db-metadata-dir>", `The directory in which to store asset database metadata. (default: "<current-dir>/.db")`];
    const keyOption: [string, string] = ["-k, --key <keyfile>", "Path to the private key file for encryption."];
    const generateKeyOption: [string, string, boolean] = ["-g, --generate-key", "Generate encryption keys if they don't exist.", false];
    const verboseOption: [string, string, boolean] = ["-v, --verbose", "Enables verbose logging.", false];
    const yesOption: [string, string, boolean] = ["-y, --yes", "Non-interactive mode. Use command line arguments and defaults.", false];

    program
        .name("psi")
        .version(version)
        .description(`The Photosphere CLI tool for managing your media file database.`)
        .addHelpText('after', `
The [database-dir] argument specifies the directory that contains the media file database and it defaults to the current directory when omitted.

Getting help:
  ${pc.bold("psi <command> --help")}    Shows help for a particular command.
  ${pc.bold("psi --help")}              Shows help for all commands.

Examples:
${MAIN_EXAMPLES.map(ex => `  ${ex.command.padEnd(32)} ${ex.description}`).join('\n')}

Resources:
  🚀 Getting Started: https://github.com/ashleydavis/photosphere/wiki/Getting-Started
  📖 Command Reference: https://github.com/ashleydavis/photosphere/wiki/Command-Reference
  📚 Wiki: https://github.com/ashleydavis/photosphere/wiki
  🐛 View Issues: https://github.com/ashleydavis/photosphere/issues
  ➕ New Issue: https://github.com/ashleydavis/photosphere/issues/new`)
        .exitOverride();  // Prevent commander from calling process.exit

    program
        .command("init")
        .description("Initializes a new media file database.")
        .argument(...dbArgument)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...generateKeyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .addHelpText('after', getCommandExamplesHelp('init'))
        .action(initCommand);

    program
        .command("add")
        .description("Adds files and directories to the media file database.")
        .argument(...dbArgument)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .argument("<files...>", "The media files (or directories) to add to the database.")
        .addHelpText('after', getCommandExamplesHelp('add'))
        .action(addCommand);

    program
        .command("check")
        .description("Checks files and direcotires to see what has already been added to the media file database.")
        .argument(...dbArgument)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .argument("<files...>", "The media files (or directories) to add to the database.")
        .addHelpText('after', getCommandExamplesHelp('check'))
        .action(checkCommand);

    program
        .command("ui")
        .description("Starts the Photosphere user-interface to view, search and edit photos and videos.")
        .argument(...dbArgument)
        .option(...keyOption)
        .option(...metadataDirOption)
        .option("--no-open", "Disables opening the UI in the default browser.", false)
        .option(...yesOption)
        .addHelpText('after', getCommandExamplesHelp('ui'))
        .action(uiCommand);

    program
        .command("configure")
        .description("Configures S3 credentials for cloud storage.")
        .option("-p, --profile <name>", "The profile name to configure", "default")
        .option("-c, --clear", "Clear all S3 configuration files")
        .option(...yesOption)
        .addHelpText('after', getCommandExamplesHelp('configure'))
        .action(configureCommand);

    program
        .command("info")
        .description("Displays detailed information about media files including EXIF data, metadata, and technical specifications.")
        .option(...verboseOption)
        .option(...yesOption)
        .argument("<files...>", "The media files to analyze.")
        .addHelpText('after', getCommandExamplesHelp('info'))
        .action(infoCommand);

    program
        .command("tools")
        .description("Checks for required media processing tools (ImageMagick, ffmpeg, ffprobe).")
        .option(...yesOption)
        .addHelpText('after', getCommandExamplesHelp('tools'))
        .action(toolsCommand);

    program
        .command("summary")
        .description("Displays a summary of the media file database including total files, size, and tree hash.")
        .argument(...dbArgument)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .addHelpText('after', getCommandExamplesHelp('summary'))
        .action(summaryCommand);

    program
        .command("verify")
        .description("Verifies the integrity of the media file database by checking file hashes.")
        .argument(...dbArgument)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option("--full", "Force full verification (bypass cached hash optimization)", false)
        .addHelpText('after', getCommandExamplesHelp('verify'))
        .action(verifyCommand);

    program
        .command("replicate")
        .description("Replicates an asset database from source to destination location.")
        .argument("[source-dir]", "Source database directory (defaults to current directory)")
        .argument("<destination-dir>", "Destination directory for replicated database")
        .option("-s, --src-meta <dir>", "Source metadata directory override")
        .option("-d, --dest-meta <dir>", "Destination metadata directory override")
        .option("--sk, --src-key <keyfile>", "Path to source encryption key file")
        .option("--dk, --dest-key <keyfile>", "Path to destination encryption key file")
        .option(...generateKeyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .addHelpText('after', getCommandExamplesHelp('replicate'))
        .action(replicateCommand);

    program
        .command("compare")
        .description("Compares two asset databases by analyzing their Merkle trees.")
        .argument("<source-dir>", "Source database directory")
        .argument("<destination-dir>", "Destination database directory")
        .option("-s, --src-meta <dir>", "Source metadata directory override")
        .option("-d, --dest-meta <dir>", "Destination metadata directory override")
        .option(...verboseOption)
        .option(...yesOption)
        .addHelpText('after', getCommandExamplesHelp('compare'))
        .action(compareCommand);

    // Add the debug command with its subcommands
    program.addCommand(createDebugCommand());

    program
        .command("examples")
        .description("Shows usage examples for all CLI commands.")
        .option(...yesOption)
        .addHelpText('after', getCommandExamplesHelp('examples'))
        .action(examplesCommand);

    program
        .command("bug-report")
        .description("Generates a bug report for GitHub with system information and logs.")
        .option(...verboseOption)
        .option(...yesOption)
        .option("--no-browser", "Don't open the browser automatically", false)
        .addHelpText('after', getCommandExamplesHelp('bug-report'))
        .action(bugReportCommand);

    // Parse the command line arguments
    try {
        await program.parseAsync(process.argv);
    } catch (err: any) {
        // Commander throws an error when no command is provided
        // Check if this is just a help display situation
        if (err.code === 'commander.help' || err.code === 'commander.helpDisplayed') {
            await exit(0);
        }
        // If no command was provided and we're showing help
        if (process.argv.length <= 2) {
            await exit(0);
        }
        throw err;
    }
}

main()
    .catch(async (error) => {
        console.error(pc.red('An error occurred:'));
        if (error.message) {
            console.error(pc.red(error.message).toString());
        }
        if (error.stack) {
            console.error((pc.red(error.stack).toString()));
        }
        else {
            console.error(pc.red(error.toString()).toString());
        }

        return exit(1);
    });