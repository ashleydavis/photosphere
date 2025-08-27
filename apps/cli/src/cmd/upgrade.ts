import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { IBaseCommandOptions, loadDatabase } from "../lib/init-cmd";
import { intro, outro, confirm } from '../lib/clack/prompts';
import { CURRENT_DATABASE_VERSION, HashCache } from "adb";
import { pathJoin } from "storage";
import type { MediaFileDatabase } from "api";
import type { IStorage } from "storage";

export interface IUpgradeCommandOptions extends IBaseCommandOptions {
    yes?: boolean;
}

//
// Performs the actual database upgrade logic for a database from a given version to the current version.
//
export async function performDatabaseUpgrade(
    database: MediaFileDatabase, 
    metadataStorage: IStorage, 
    currentVersion: number
): Promise<void> {
    log.info(`Upgrading database from version ${currentVersion} to version ${CURRENT_DATABASE_VERSION}...`);
    
    // For any upgrade from version 2, copy file metadata from hash cache to merkle tree
    if (currentVersion === 2) {
        log.info(`Copying file metadata from hash cache to merkle tree...`);
        
        // Load the hash cache
        const hashCache = new HashCache(metadataStorage, "", false);
        const cacheLoaded = await hashCache.load();
        
        if (cacheLoaded) {
            // Get the merkle tree and update leaf nodes with file metadata
            const assetDb = database.getAssetDatabase();
            const merkleTree = assetDb.getMerkleTree();
            
            // Track how many files we updated
            let filesUpdated = 0;
            
            // Update leaf nodes with lastModified from hash cache
            for (const node of merkleTree.nodes) {
                if (node.fileName) { // This is a leaf node
                    const cacheEntry = hashCache.getHash(node.fileName);
                    if (cacheEntry) {
                        node.lastModified = cacheEntry.lastModified;
                        filesUpdated++;
                    }
                }
            }
            
            log.info(`✓ Updated ${filesUpdated} files with metadata from hash cache`);
        }
        
        // Final pass: get lastModified from filesystem for any files that still don't have it
        log.info(`Checking filesystem for any missing file dates...`);
        const assetStorage = database.getAssetStorage();
        const merkleTree = database.getAssetDatabase().getMerkleTree();
        let filesFromFilesystem = 0;
        
        for (const node of merkleTree.nodes) {
            if (node.fileName && !node.lastModified) {
                try {
                    const fileInfo = await assetStorage.info(node.fileName);
                    if (fileInfo) {
                        node.lastModified = fileInfo.lastModified;
                        filesFromFilesystem++;
                    }
                } catch (error) {
                    // File might not exist anymore, skip silently
                    log.verbose(`Could not get file info for ${node.fileName}: ${error instanceof Error ? error.message : 'Unknown error'}`);
                }
            }
        }
        
        if (filesFromFilesystem > 0) {
            log.info(`✓ Retrieved dates from filesystem for ${filesFromFilesystem} files`);
        }
    }
    
    // Save the database - this will write in the latest format
    await database.getAssetDatabase().save();
    
    // Delete the hash cache file after successful upgrade from version 2
    if (currentVersion === 2) {
        const hashCachePath = pathJoin("", "hash-cache-x.dat");
        if (await metadataStorage.fileExists(hashCachePath)) {
            await metadataStorage.deleteFile(hashCachePath);
            log.info(`✓ Removed hash cache file (no longer needed in version ${CURRENT_DATABASE_VERSION})`);
        }
    }
    
    log.info(pc.green(`✓ Database upgraded successfully to version ${CURRENT_DATABASE_VERSION}`));
}

//
// Command that upgrades a Photosphere media file database to the latest format.
//
export async function upgradeCommand(options: IUpgradeCommandOptions): Promise<void> {
    
    intro(pc.blue(`Upgrading media file database...`));

    // Load the database in readonly mode to check version without modifications
    const { database } = await loadDatabase(options.db, options, true, true);

    // Get the current tree version
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
            log.warn(pc.yellow(`   xcopy "${options.db}" "${options.db}-backup" /E /I`));
        } 
        else {
            log.warn(pc.yellow(`   cp -r "${options.db}" "${options.db}-backup"`));
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
        
        // Reload the database for upgrade
        const { database: upgradeDatabase, metadataStorage } = await loadDatabase(options.db, options, true);
        
        // Perform the upgrade using the reusable function
        await performDatabaseUpgrade(upgradeDatabase, metadataStorage, currentVersion);        
    } 
    else {
        outro(pc.red(`✗ Database version ${currentVersion} is newer than the current supported version ${CURRENT_DATABASE_VERSION}.\n  Please update your Photosphere CLI tool.`));
        await exit(1);
        return;
    }

    await exit(0);
}