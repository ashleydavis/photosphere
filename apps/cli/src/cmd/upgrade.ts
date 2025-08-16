import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { IBaseCommandOptions, loadDatabase } from "../lib/init-cmd";
import { intro, outro } from '../lib/clack/prompts';
import { CURRENT_DATABASE_VERSION } from "adb";

export interface IUpgradeCommandOptions extends IBaseCommandOptions {
}

//
// Command that upgrades a Photosphere media file database to the latest format.
//
export async function upgradeCommand(options: IUpgradeCommandOptions): Promise<void> {
    
    intro(pc.blue(`Upgrading media file database...`));

    // Load the database (allowing older versions for upgrade)
    const { database } = await loadDatabase(options.db, options, true);

    // Get the current tree version
    const merkleTree = database.getAssetDatabase().getMerkleTree();
    const currentVersion = merkleTree.version;

    log.info(`✓ Found database version ${currentVersion}`);

    if (currentVersion === CURRENT_DATABASE_VERSION) {
        log.info(pc.green(`✓ Database is already at the latest version (${CURRENT_DATABASE_VERSION})`));
    } else if (currentVersion < CURRENT_DATABASE_VERSION) {
        log.info(`Upgrading database from version ${currentVersion} to version ${CURRENT_DATABASE_VERSION}...`);
        
        // Save the tree - this will write it in the latest format
        await database.getAssetDatabase().save();
        
        log.info(pc.green(`✓ Database upgraded successfully to version ${CURRENT_DATABASE_VERSION}`));
    } else {
        outro(pc.red(`✗ Database version ${currentVersion} is newer than the current supported version ${CURRENT_DATABASE_VERSION}.\n  Please update your Photosphere CLI tool.`));
        await exit(1);
    }

    // Close the database
    await database.close();      

    await exit(0);
}