import { program } from 'commander';
import { version } from '../package.json';
import express from 'express';
import path from 'path';
import fs from 'fs';
import AdmZip from "adm-zip";
import os from 'os';

import pfe from  "../pfe.zip" with { type: "file" } ;

//
// Extract frontend code if doesn't exist.
//
const frontendPath = path.join(os.tmpdir(), "photosphere/frontend/v1");
if (!fs.existsSync(frontendPath)) {
    fs.mkdirSync(frontendPath, { recursive: true });

    const zip = new AdmZip(fs.readFileSync(pfe));
    zip.extractAllTo(frontendPath, true); //TODO: Could also just stream the contents without extracing it.

    console.log(`Extracted frontend to ${frontendPath}.`);
}
else {
    console.log(`Frontend already exists at ${frontendPath}.`);
}

console.log(`Serving frontend from ${frontendPath}.`);

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
            app.use(express.static(path.join(frontendPath, "dist")));
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