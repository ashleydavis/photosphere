import { program } from 'commander';
import { version } from '../package.json';
import express from 'express';

async function main() {

    program
        .name("psi")
        .version(version)
        .description("The Photosphere CLI tool for managing your media file library.");

    program
        .command("edit")
        .description("Starts the Photosphere editor to view, search and edit photos and videos.")
        .action(async () => {
            //
            // Start an express server to serve static files.
            //
            const app = express();
            app.use(express.static("public"));
            app.listen(3000, () => {
               console.log("Photosphere editor started at http://localhost:3000");
            });
        });

    await program.parseAsync(process.argv);
}

main()
    .catch(error => {
        console.error('An error occurred:');
        console.error(error.stack || error.message || error);
    });