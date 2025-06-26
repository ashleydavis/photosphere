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
    log.info('Your database is ready to receive photos and videos!');
    log.info('');
    log.info(pc.yellow('⚠️  Important: Never modify database files manually - always use the psi tool!'));
    log.info('');
    log.info('To get started:');
    if (isCurrentDir) {
        log.info(`  1. ` + pc.cyan(`psi add <source-media-directory>`) + pc.blue(` (add your photos and videos)`));
    } else {
        log.info(`  1. ` + pc.cyan(`cd ${databaseDir}`) + pc.blue(` (change to your database directory)`));
        log.info(`  2. ` + pc.cyan(`psi add <source-media-directory>`) + pc.blue(` (add your photos and videos)`));
    }
    log.info('');
    if (!isCurrentDir) {
        log.info(`Or identify the database using the path: ` + pc.cyan(`psi add --db ${databaseDir} <source-media-directory>`));
    }

    if (options.key) {
        log.info('');
        log.info('When using your encrypted database, specify the key file:');
        log.info(`  ` + pc.cyan(`psi add --key ${options.key} <source-media-directory>`));
    }

    // Show follow-up commands
    log.info('');
    log.info(pc.bold('Next steps after adding files:'));
    const dbFlag = isCurrentDir ? '' : ` --db ${databaseDir}`;
    const keyFlag = options.key ? ` --key ${options.key}` : '';
    const flags = `${dbFlag}${keyFlag}`;
    log.info(`  ${pc.cyan(`psi verify${flags}`)}                    Verify the integrity of your database`);
    log.info(`  ${pc.cyan(`psi summary${flags}`)}                   View database summary and statistics`);
    log.info(`  ${pc.cyan(`psi replicate${flags} --dest <path>`)}   Create a backup copy of your database`);
    log.info(`  ${pc.cyan(`psi ui${flags}`)}                        Open the web interface to browse your media`);

    await exit(0);
}