import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { createDatabase, ICreateCommandOptions } from "../lib/init-cmd";

export interface IInitCommandOptions extends ICreateCommandOptions {}

//
// Command that initializes a new Photosphere media file database.
//
export async function initCommand(dbDir: string, options: IInitCommandOptions): Promise<void> {

    const { database, databaseDir } = await createDatabase(dbDir, options, false, true);

    log.info('');
    log.info(pc.green(`✓ Created new media file database in "${databaseDir}"`));
    log.info('');
    log.info(pc.dim('Your database is ready to receive photos and videos!'));
    log.info('');
    log.info(pc.dim('To get started:'));
    log.info(pc.dim(`  1. ${pc.cyan(`cd ${databaseDir}`)} (change to your database directory)`));
    log.info(pc.dim(`  2. ${pc.cyan(`psi add <source-media-directory>`)} (add your photos and videos)`));
    log.info('');
    log.info(pc.dim(`Or use the full path: ${pc.cyan(`psi add ${databaseDir} <source-media-directory>`)}`));

    await exit(0);
}