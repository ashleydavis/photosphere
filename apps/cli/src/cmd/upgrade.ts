import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { IBaseCommandOptions, loadDatabase } from "../lib/init-cmd";
import { intro, outro, confirm } from '../lib/clack/prompts';
import { CURRENT_DATABASE_VERSION } from "adb";

export interface IUpgradeCommandOptions extends IBaseCommandOptions {
    yes?: boolean;
}

//
// Command that upgrades a Photosphere media file database to the latest format.
//
export async function upgradeCommand(options: IUpgradeCommandOptions): Promise<void> {
    
    intro(pc.blue(`Upgrading media file database...`));

    // Load the database in readonly mode to check version without modifications.
    const { database, databaseDir } = await loadDatabase(options.db, options, true, true);

    const merkleTree = database.getAssetDatabase().getMerkleTree();
    const currentVersion = merkleTree.version;

    log.info(`✓ Found database version ${currentVersion}`);

    if (currentVersion === CURRENT_DATABASE_VERSION) {
        log.info(pc.green(`✓ Database is already at the latest version (${CURRENT_DATABASE_VERSION})`));
    } 
    else if (currentVersion < CURRENT_DATABASE_VERSION) {        
        log.warn(pc.yellow(`⚠️  IMPORTANT: Database upgrade will modify your database files.`));
        log.warn(pc.yellow(`   It is strongly recommended to backup your database before proceeding.`));
        log.warn(pc.yellow(`   You can backup your database by copying the entire directory:`));
        
        // Provide platform-specific backup commands
        if (process.platform === 'win32') {
            log.warn(pc.yellow(`   xcopy "${databaseDir}" "${databaseDir}-backup" /E /I`));
        } 
        else {
            log.warn(pc.yellow(`   cp -r "${databaseDir}" "${databaseDir}-backup"`));
        }
        console.log("");
        
        let shouldProceed: boolean;
        
        if (options.yes) {
            // Non-interactive mode: proceed automatically
            log.info(pc.blue(`✓ Non-interactive mode: proceeding with database upgrade`));
            shouldProceed = true;
        } else {
            // Interactive mode: ask for confirmation
            const confirmResult = await confirm({
                message: `Do you want to proceed with upgrading from version ${currentVersion} to version ${CURRENT_DATABASE_VERSION}?`,
                initialValue: false,
            });
            shouldProceed = confirmResult === true;
        }
        
        if (!shouldProceed) {
            outro(pc.gray("Database upgrade cancelled."));
            await exit(0);
            return;
        }
        
        log.info(`Upgrading database from version ${currentVersion} to version ${CURRENT_DATABASE_VERSION}...`);

        // Reload the database for upgrade in readwrite mode.
        // The updated database is automatically saved.
        await loadDatabase(options.db, options, true, false);

        log.info(pc.green(`✓ Database upgraded successfully to version ${CURRENT_DATABASE_VERSION}`));
    } 
    else {
        outro(pc.red(`✗ Database version ${currentVersion} is newer than the current supported version ${CURRENT_DATABASE_VERSION}.\n  Please update your Photosphere CLI tool.`));
        await exit(1);
        return;
    }

    await exit(0);
}