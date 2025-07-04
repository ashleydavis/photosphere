import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { createDatabase, ICreateCommandOptions } from "../lib/init-cmd";
import { intro, outro } from '../lib/clack/prompts';

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

    log.info('');
    log.info(pc.green(`✓  Created new media file database in ${displayPath}`));
    log.info(pc.yellow('⚠️ Important: Never modify database files manually - always use the psi tool!'));
    
    if (options.generateKey && options.key) {
        log.info('');
        log.info(pc.green(`✓  Encryption key saved to: ${options.key}, public key: ${options.key}.pub`));
        log.info(pc.yellow(`⚠️ Keep this key file safe! You will need it to access your encrypted database.`));
    }

    
    log.info('');
    log.info('');
    log.info(pc.bold('Add media files:'));
    if (isCurrentDir) {
        log.info(`    ` + pc.cyan(`psi add <file or directory>`));
    } else {
        log.info(`    ` + pc.cyan(`cd ${databaseDir}`));
        log.info(`    ` + pc.cyan(`psi add <file or directory>`));
    }
    log.info('');
    if (!isCurrentDir) {
        log.info(`Or specify the path:`);
        log.info(`    ` + pc.cyan(`psi add --db ${databaseDir} <file or directory>`));
    }

    if (options.key) {
        log.info('');
        log.info('When using your encrypted database, specify the key file:');
        log.info(`    ` + pc.cyan(`psi add --key ${options.key} <source-media-directory>`));
    }

    // Show follow-up commands
    log.info('');
    log.info(pc.bold('Examples:'));
    const dbFlag = isCurrentDir ? '' : ` --db ${databaseDir}`;
    const keyFlag = options.key ? ` --key ${options.key}` : '';
    const flags = `${dbFlag}${keyFlag}`;
    log.info(`    ${pc.cyan(`psi add${flags} photo.jpg`)}   - Adds a single photo to the database`);
    log.info(`    ${pc.cyan(`psi add${flags} video.mp4`)}   - Adds a single video to the database`);
    log.info(`    ${pc.cyan(`psi add${flags} directory/`)}  - Adds all media files in a directory`);
    log.info('');
   
    await exit(0);
}