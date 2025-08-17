import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { IBaseCommandOptions, loadDatabase } from "../lib/init-cmd";
import { intro, outro, confirm } from '../lib/clack/prompts';
import { CURRENT_DATABASE_VERSION } from "adb";

export interface IUpgradeCommandOptions extends IBaseCommandOptions {
}

//
// Command that upgrades a Photosphere media file database to the latest format.
//
export async function upgradeCommand(options: IUpgradeCommandOptions): Promise<void> {
    
    intro(pc.blue(`Upgrading media file database...`));

    // Load the database in readonly mode to check version without modifications
    const { database } = await loadDatabase(options.db, options, true, true); // allowOlderVersions: true, readonly: true

    // Get the current tree version
    const merkleTree = database.getAssetDatabase().getMerkleTree();
    const currentVersion = merkleTree.version;

    log.info(`✓ Found database version ${currentVersion}`);

    if (currentVersion === CURRENT_DATABASE_VERSION) {
        log.info(pc.green(`✓ Database is already at the latest version (${CURRENT_DATABASE_VERSION})`));
        await database.close();
    } else if (currentVersion < CURRENT_DATABASE_VERSION) {
        // Close readonly database before prompting for backup
        await database.close();
        
        log.warn(pc.yellow(`⚠️  IMPORTANT: Database upgrade will modify your database files.`));
        log.warn(pc.yellow(`   It is strongly recommended to backup your database before proceeding.`));
        log.warn(pc.yellow(`   You can backup your database by copying the entire directory:`));
        
        // Provide platform-specific backup commands
        if (process.platform === 'win32') {
            log.warn(pc.yellow(`   xcopy "${options.db}" "${options.db}-backup" /E /I`));
        } else {
            log.warn(pc.yellow(`   cp -r "${options.db}" "${options.db}-backup"`));
        }
        console.log("");
        
        const shouldProceed = await confirm({
            message: `Do you want to proceed with upgrading from version ${currentVersion} to version ${CURRENT_DATABASE_VERSION}?`,
            initialValue: false,
        });
        
        if (!shouldProceed) {
            outro(pc.gray("Database upgrade cancelled."));
            await exit(0);
        }
        
        // Reload the database for upgrade
        const { database: upgradeDatabase } = await loadDatabase(options.db, options, true);
        
        log.info(`Upgrading database from version ${currentVersion} to version ${CURRENT_DATABASE_VERSION}...`);
        
        // Save the tree - this will write it in the latest format
        await upgradeDatabase.getAssetDatabase().save();
        
        log.info(pc.green(`✓ Database upgraded successfully to version ${CURRENT_DATABASE_VERSION}`));
        
        // Close the upgraded database
        await upgradeDatabase.close();
    } else {
        outro(pc.red(`✗ Database version ${currentVersion} is newer than the current supported version ${CURRENT_DATABASE_VERSION}.\n  Please update your Photosphere CLI tool.`));
        await database.close();
        await exit(1);
    }

    await exit(0);
}