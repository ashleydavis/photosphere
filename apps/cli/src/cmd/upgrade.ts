import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { IBaseCommandOptions } from "../lib/init-cmd";
import { configureLog } from "../lib/log";
import { createStorage, pathJoin } from "storage";
import { getS3Config } from "../lib/config";
import { intro, outro } from '../lib/clack/prompts';

export interface IUpgradeCommandOptions extends IBaseCommandOptions {
}

//
// Command that upgrades a Photosphere media file database to the latest format.
//
export async function upgradeCommand(options: IUpgradeCommandOptions): Promise<void> {
    
    intro(pc.blue(`Upgrading media file database...`));

    const nonInteractive = options.yes || false;
    
    // Configure logging
    await configureLog({
        verbose: options.verbose,
        tools: options.tools
    });

    // Use provided db directory or current directory
    const dbDir = options.db || ".";
    const metaPath = options.meta || pathJoin(dbDir, '.db');

    log.verbose(`Database directory: ${dbDir}`);
    log.verbose(`Metadata directory: ${metaPath}`);

    try {
        const s3Config = await getS3Config();
        const { storage: metadataStorage } = createStorage(metaPath, s3Config);

        // Check if this is a valid database directory
        if (!await metadataStorage.fileExists('tree.dat')) {
            outro(pc.red(`✗ No database found at: ${pc.cyan(dbDir)}\n  The database directory must contain a ".db" folder with the database metadata (tree.dat file).\n\nThis doesn't appear to be a valid Photosphere database directory.`));
            await exit(1);
        }

        log.info(`✓ Found valid database at ${dbDir}`);

        // Check if metadata.json exists
        const metadataExists = await metadataStorage.fileExists('metadata.json');
        
        if (!metadataExists) {
            log.info(`Adding missing metadata.json file...`);
            
            // Create the default metadata.json structure
            const defaultMetadata = {
                filesImported: 0,
                version: 1
            };

            // Write the metadata.json file
            const metadataContent = JSON.stringify(defaultMetadata, null, 2);
            await metadataStorage.write('metadata.json', 'application/json', Buffer.from(metadataContent, 'utf-8'));
            
            log.info(pc.green(`✓ Created metadata.json file`));
        } else {
            log.info(`✓ metadata.json already exists`);
        }

        // Check for other expected files
        const expectedFiles = ['tree.dat'];
        const missingFiles = [];

        for (const file of expectedFiles) {
            if (!await metadataStorage.fileExists(file)) {
                missingFiles.push(file);
            }
        }

        if (missingFiles.length > 0) {
            log.info('');
            log.info(pc.yellow(`⚠️  Missing expected files: ${missingFiles.join(', ')}`));
            log.info(pc.yellow(`   This may indicate database corruption or an incomplete database.`));
        }

        log.info('');
        log.info(pc.green(`✓ Database upgrade completed successfully`));
        
    } catch (error) {
        log.error(`Failed to upgrade database: ${error instanceof Error ? error.message : 'Unknown error'}`);
        await exit(1);
    }

    await exit(0);
}