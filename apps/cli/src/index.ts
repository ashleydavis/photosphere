import { program } from 'commander';
import { version } from '../package.json';
import { uiCommand } from './cmd/ui';
import { addCommand } from './cmd/add';
import { initCommand } from './cmd/init';

async function main() {

    const dbArgument: [string, string, string] = ["[database-dir]", "The directory that contains the media file database. Defaults to the current directory.", process.cwd()];

    program
        .name("psi")
        .version(version)
        .description("The Photosphere CLI tool for managing your media file database.");

    program
        .command("init")
        .description("Initializes a new Photosphere media file database.")
        .argument(...dbArgument)
        .action(initCommand);

    program
        .command("add")
        .description("Add files and directories to the Photosphere media file database.")
        .argument(...dbArgument)
        .argument("<files...>", "The media files to stage for adding to the database.")
        .action(addCommand);

    program
        .command("ui")
        .description("Starts the Photosphere editor to view, search and edit photos and videos.")
        .action(uiCommand);

    await program.parseAsync(process.argv);
}

main()
    .catch(error => {
        console.error('An error occurred:');
        console.error(error.stack || error.message || error);
    });