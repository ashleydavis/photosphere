import { program } from 'commander';
import { version } from '../package.json';
import { uiCommand } from './cmd/ui';

async function main() {

    program
        .name("psi")
        .version(version)
        .description("The Photosphere CLI tool for managing your media file library.");

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