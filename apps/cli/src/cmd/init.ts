import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { createDatabase, ICreateCommandOptions } from "../lib/init-cmd";

export interface IInitCommandOptions extends ICreateCommandOptions {
}

//
// Command that initializes a new Photosphere media file database.
//
export async function initCommand(options: IInitCommandOptions): Promise<void> {

    await createDatabase(options.db, options, false, true);

    const displayPath = (options.db === "." || options.db === "./") ? "current directory" : options.db;
    const isCurrentDir = options.db === "." || options.db === "./";

    log.info('');
    log.info(pc.green(`✓ Created new media file database in ${isCurrentDir ? "the " : "\""}${displayPath}${isCurrentDir ? "" : "\""}"`));
    log.info('');
    log.info(pc.dim('Your database is ready to receive photos and videos!'));
    log.info('');
    log.info(pc.dim('To get started:'));
    if (isCurrentDir) {
        log.info(pc.dim(`  1. ${pc.cyan(`psi add <source-media-directory>`)} (add your photos and videos)`));
    } else {
        log.info(pc.dim(`  1. ${pc.cyan(`cd ${options.db}`)} (change to your database directory)`));
        log.info(pc.dim(`  2. ${pc.cyan(`psi add <source-media-directory>`)} (add your photos and videos)`));
    }
    log.info('');
    if (!isCurrentDir) {
        log.info(pc.dim(`Or identify the database using the path: ${pc.cyan(`psi add --db ${options.db} <source-media-directory>`)}`));
    }

    await exit(0);
}