import { program } from 'commander';
import { version } from '../package.json';
import { uiCommand } from './cmd/ui';
import { addCommand } from './cmd/add';
import { checkCommand } from './cmd/check';
import { initCommand } from './cmd/init';
import { configureCommand } from './cmd/configure';
import { infoCommand } from './cmd/info';
import { toolsCommand } from './cmd/tools';
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
        .description("The Photosphere CLI tool for managing your media file database.")
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
        .action(initCommand);

    program
        .command("add")
        .description("Add files and directories to the media file database.")
        .argument(...dbArgument)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .argument("<files...>", "The media files (or directories) to add to the database.")
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
        .action(checkCommand);

    program
        .command("ui")
        .description("Starts the Photosphere user-interface to view, search and edit photos and videos.")
        .argument(...dbArgument)
        .option(...keyOption)
        .option(...metadataDirOption)
        .option("--no-open", "Disables opening the UI in the default browser.", false)
        .option(...yesOption)
        .action(uiCommand);

    program
        .command("configure")
        .description("Configure S3 credentials for cloud storage.")
        .option("-p, --profile <name>", "The profile name to configure", "default")
        .option("-c, --clear", "Clear all S3 configuration files")
        .option(...yesOption)
        .action(configureCommand);

    program
        .command("info")
        .description("Display detailed information about media files including EXIF data, metadata, and technical specifications.")
        .option(...verboseOption)
        .option(...yesOption)
        .option("-r, --raw", "Show raw EXIF/metadata properties", false)
        .argument("<files...>", "The media files to analyze.")
        .action(infoCommand);

    program
        .command("tools")
        .description("Check for required media processing tools (ImageMagick, ffmpeg, ffprobe).")
        .option(...yesOption)
        .action(toolsCommand);

    // Parse the command line arguments
    try {
        await program.parseAsync(process.argv);
    } catch (err: any) {
        // Commander throws an error when no command is provided
        // Check if this is just a help display situation
        if (err.code === 'commander.help' || err.code === 'commander.helpDisplayed') {
            exit(0);
        }
        // If no command was provided and we're showing help
        if (process.argv.length <= 2) {
            exit(0);
        }
        throw err;
    }
}

main()
    .catch(error => {
        console.error(pc.red('An error occurred:'));
        console.error((pc.red(error.stack || error.message || error).toString()));

        exit(1);
    });