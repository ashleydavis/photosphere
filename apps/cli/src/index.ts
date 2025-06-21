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
Examples:
  psi init ./photos                    Create a new database in ./photos directory.
  psi add ./photos ~/Pictures          Add all media files from ~/Pictures to database.
  psi summary ./photos                 Show database summary (file count, size, etc.).
  psi verify ./photos                  Verify database integrity.
  psi replicate ./photos ./backup      Replicate database to backup location.
  psi compare ./photos ./backup        Compare two databases for differences.

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
        .addHelpText('after', `
Examples:
  psi init                             Create database in current directory.
  psi init ./photos                    Create database in ./photos directory.
  psi init ./photos -m ./photos-meta   Create with custom metadata directory.`)
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
        .addHelpText('after', `
Examples:
  psi add ./photos ~/Pictures          Add all files from ~/Pictures to database.
  psi add ./photos image.jpg video.mp4 Add specific files to database.
  psi add ./photos ~/Downloads/photos  Add directory recursively.`)
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
        .addHelpText('after', `
Examples:
  psi check ./photos ~/Pictures        Check which files from ~/Pictures are already in database.
  psi check ./photos image.jpg         Check if specific file is already in database.
  psi check ./photos ~/Downloads       Check directory to see what's already been added.`)
        .action(checkCommand);

    program
        .command("ui")
        .description("Starts the Photosphere user-interface to view, search and edit photos and videos.")
        .argument(...dbArgument)
        .option(...keyOption)
        .option(...metadataDirOption)
        .option("--no-open", "Disables opening the UI in the default browser.", false)
        .option(...yesOption)
        .addHelpText('after', `
Examples:
  psi ui                               Start UI for database in current directory.
  psi ui ./photos                      Start UI for database in ./photos directory.
  psi ui ./photos --no-open            Start UI without opening browser automatically.`)
        .action(uiCommand);

    program
        .command("configure")
        .description("Configure S3 credentials for cloud storage.")
        .option("-p, --profile <name>", "The profile name to configure", "default")
        .option("-c, --clear", "Clear all S3 configuration files")
        .option(...yesOption)
        .addHelpText('after', `
Examples:
  psi configure                        Configure S3 credentials for default profile.
  psi configure -p mycloud             Configure S3 credentials for 'mycloud' profile.
  psi configure --clear                Clear all S3 configuration files.`)
        .action(configureCommand);

    program
        .command("info")
        .description("Display detailed information about media files including EXIF data, metadata, and technical specifications.")
        .option(...verboseOption)
        .option(...yesOption)
        .argument("<files...>", "The media files to analyze.")
        .addHelpText('after', `
Examples:
  psi info photo.jpg                   Show detailed information about a photo.
  psi info photo1.jpg photo2.jpg       Analyze multiple specific files.
  psi info ~/Pictures                  Analyze all media files in a directory.`)
        .action(infoCommand);

    program
        .command("tools")
        .description("Check for required media processing tools (ImageMagick, ffmpeg, ffprobe).")
        .option(...yesOption)
        .addHelpText('after', `
Examples:
  psi tools                            Check status of all required tools.`)
        .action(toolsCommand);

    program
        .command("summary")
        .description("Display a summary of the media file database including total files, size, and tree hash.")
        .argument(...dbArgument)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .addHelpText('after', `
Examples:
  psi summary                          Show summary for database in current directory.
  psi summary ./photos                 Show summary for database in ./photos directory.`)
        .action(summaryCommand);

    program
        .command("verify")
        .description("Verify the integrity of the media file database by checking file hashes.")
        .argument(...dbArgument)
        .option(...metadataDirOption)
        .option(...keyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .option("--full", "Force full verification (bypass cached hash optimization)", false)
        .addHelpText('after', `
Examples:
  psi verify                           Verify database in current directory.
  psi verify ./photos                  Verify database in ./photos directory.
  psi verify ./photos --full           Force full verification of all files.`)
        .action(verifyCommand);

    program
        .command("replicate")
        .description("Replicate an asset database from source to destination location.")
        .argument("[source-dir]", "Source database directory (defaults to current directory)")
        .argument("<destination-dir>", "Destination directory for replicated database")
        .option("-s, --src-meta <dir>", "Source metadata directory override")
        .option("-d, --dest-meta <dir>", "Destination metadata directory override")
        .option("--sk, --src-key <keyfile>", "Path to source encryption key file")
        .option("--dk, --dest-key <keyfile>", "Path to destination encryption key file")
        .option(...generateKeyOption)
        .option(...verboseOption)
        .option(...yesOption)
        .addHelpText('after', `
Examples:
  psi replicate ./photos ./backup      Replicate database to backup location.
  psi replicate . s3:bucket/photos     Replicate current database to S3.
  psi replicate ./photos ./remote -d ./remote-meta  Use custom metadata directory.`)
        .action(replicateCommand);

    program
        .command("compare")
        .description("Compare two asset databases by analyzing their Merkle trees.")
        .argument("<source-dir>", "Source database directory")
        .argument("<destination-dir>", "Destination database directory")
        .option("-s, --src-meta <dir>", "Source metadata directory override")
        .option("-d, --dest-meta <dir>", "Destination metadata directory override")
        .option(...verboseOption)
        .option(...yesOption)
        .addHelpText('after', `
Examples:
  psi compare ./photos ./backup        Compare original database with backup.
  psi compare . s3:bucket/photos       Compare local database with S3 version.
  psi compare ./photos ./mirror -s ./photos-meta  Use custom metadata directories.`)
        .action(compareCommand);

    // Add the debug command with its subcommands
    program.addCommand(createDebugCommand());

    program
        .command("bug-report")
        .description("Generate a bug report for GitHub with system information and logs.")
        .option(...verboseOption)
        .option(...yesOption)
        .option("--no-browser", "Don't open the browser automatically", false)
        .addHelpText('after', `
Examples:
  psi bug-report                       Generate bug report and open in browser.
  psi bug-report --no-browser          Generate bug report without opening browser.`)
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