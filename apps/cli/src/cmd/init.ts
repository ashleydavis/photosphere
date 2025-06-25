import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { createDatabase, ICreateCommandOptions } from "../lib/init-cmd";
import { intro, outro } from "@clack/prompts";

export interface IInitCommandOptions extends ICreateCommandOptions {
}

//
// Command that initializes a new Photosphere media file database.
//
export async function initCommand(options: IInitCommandOptions): Promise<void> {

    intro(pc.blue(`Creating a new media file database...`));

    const { databaseDir } = await createDatabase(options.db, options);

    const isCurrentDir = databaseDir === "." || databaseDir === "./";
    const displayPath = isCurrentDir ? "the current directory" : databaseDir;

    outro(pc.green(`✓ Created new media file database in "${displayPath}"`));
    
    if (options.generateKey && options.key) {
        log.info(pc.green(`✓ Encryption key saved to: ${options.key}`));
        log.info(pc.green(`✓ Public key saved to: ${options.key}.pub`));
    }
    
    log.info('');
    log.info(pc.blue('Your database is ready to receive photos and videos!'));
    log.info('');
    log.info(pc.blue('To get started:'));
    if (isCurrentDir) {
        log.info(pc.blue(`  1. `) + pc.cyan(`psi add <source-media-directory>`) + pc.blue(` (add your photos and videos)`));
    } else {
        log.info(pc.blue(`  1. `) + pc.cyan(`cd ${databaseDir}`) + pc.blue(` (change to your database directory)`));
        log.info(pc.blue(`  2. `) + pc.cyan(`psi add <source-media-directory>`) + pc.blue(` (add your photos and videos)`));
    }
    log.info('');
    if (!isCurrentDir) {
        log.info(pc.blue(`Or identify the database using the path: `) + pc.cyan(`psi add --db ${databaseDir} <source-media-directory>`));
    }

    if (options.key) {
        log.info('');
        log.info(pc.blue('When using your encrypted database, specify the key file:'));
        log.info(pc.blue(`  `) + pc.cyan(`psi add --key ${options.key} <source-media-directory>`));
    }

    await exit(0);
}