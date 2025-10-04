import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";
import { formatBytes } from "../lib/format";
import { updateFile } from "adb";

export interface IDebugUpdateCommandOptions extends IBaseCommandOptions {
    //
    // Force full verification and update (bypass cached hash optimization).
    //
    full?: boolean;

    //
    // Path to a specific file or directory to update (instead of entire database).
    //
    path?: string;

    //
    // Show what would be updated without making changes.
    //
    dryRun?: boolean;
}

//
// Command that updates file hashes in the database when they don't match the actual files.
// This is similar to verify but it fixes the hash mismatches instead of just reporting them.
//
export async function debugUpdateCommand(options: IDebugUpdateCommandOptions): Promise<void> {
    
    const { database } = await loadDatabase(options.db, options, false, false);

    const actionText = options.dryRun ? 'Checking files for' : 'Updating database with';
    writeProgress(options.path 
        ? `🔄 ${actionText} hash updates matching: ${options.path}` 
        : `🔄 ${actionText} hash updates`);

    const verifyResult = await database.verify({ 
        full: options.full,
        pathFilter: options.path
    }, (progress) => {
        writeProgress(`🔍 ${progress}`);
    });

    clearProgressMessage();

    // Count files that would be updated (modified files only)
    const filesToUpdate = verifyResult.modified;
    
    if (filesToUpdate.length === 0) {
        log.info('');
        log.info(pc.bold(pc.green(`✅ No hash updates needed - all files match their database records`)));
        log.info('');
        await exit(0);
        return;
    }

    log.info('');
    log.info(pc.bold(pc.blue(options.path 
        ? `📊 Hash update analysis for files matching: ${options.path}` 
        : `📊 Hash update analysis for database`)));
    log.info('');
    
    log.info(`Files imported:   ${pc.cyan(verifyResult.filesImported.toString())}`);
    log.info(`Total files:      ${pc.cyan(verifyResult.totalFiles.toString())}`);
    log.info(`Total size:       ${pc.cyan(formatBytes(verifyResult.totalSize))}`);
    log.info(`Files processed:  ${pc.cyan(verifyResult.filesProcessed.toString())}`);
    log.info(`Files to update:  ${pc.yellow(filesToUpdate.length.toString())}`);
    
    if (options.dryRun) {
        log.info('');
        log.info(pc.yellow(`Files that would be updated:`));
        filesToUpdate.forEach(file => {
            log.info(`  ${pc.yellow('~')} ${file}`);
        });
        
        log.info('');
        log.info(pc.blue(`📝 Dry run completed - no changes were made`));
        log.info('');
        log.info(pc.bold('To perform the actual updates, run:'));
        const baseCommand = `psi debug update`;
        const fullFlag = options.full ? ' --full' : '';
        const pathFlag = options.path ? ` --path "${options.path}"` : '';
        log.info(`    ${pc.cyan(baseCommand + fullFlag + pathFlag)}`);
        
        await exit(0);
        return;
    }

    // Perform the actual updates
    log.info('');
    log.info(pc.yellow(`🔄 Updating file hashes in database...`));
    
    let updatedCount = 0;
    let failedCount = 0;
    
    for (const filePath of filesToUpdate) {
        try {
            writeProgress(`🔄 Updating: ${filePath}`);
            
            // Get the file info from storage to recalculate hash
            const assetStorage = database.getAssetStorage();
            const fileInfo = await assetStorage.info(filePath);
            if (!fileInfo) {
                throw new Error(`File not found in storage: ${filePath}`);
            }
            
            // Compute the new hash for the file
            const newHashedFile = await database.computeAssetHash(filePath, fileInfo, () => assetStorage.readStream(filePath));
            
            // Create the FileHash object for updateFile
            const fileHash = {
                fileName: filePath,
                hash: newHashedFile.hash,
                length: newHashedFile.length,
                lastModified: newHashedFile.lastModified
            };
            
            // Get the asset database and merkle tree
            const assetDatabase = database.getAssetDatabase();
            const merkleTree = assetDatabase.getMerkleTree();
            
            // Update the file in the merkle tree
            const success = updateFile(merkleTree, fileHash);
            if (!success) {
                throw new Error(`File not found in merkle tree: ${filePath}`);
            }
            
            updatedCount++;
            
        } catch (error) {
            log.error(`Failed to update ${filePath}: ${error instanceof Error ? error.message : String(error)}`);
            failedCount++;
        }
    }
    
    // Save the database to persist changes
    if (updatedCount > 0) {
        writeProgress(`💾 Saving database changes...`);
        const assetDatabase = database.getAssetDatabase();
        await assetDatabase.save();
    }
    
    clearProgressMessage();
    
    log.info('');
    log.info(pc.bold(pc.green(`✅ Hash update completed`)));
    log.info('');
    log.info(`Files updated:    ${pc.green(updatedCount.toString())}`);
    log.info(`Files failed:     ${failedCount > 0 ? pc.red(failedCount.toString()) : pc.green('0')}`);
    
    if (failedCount > 0) {
        log.info('');
        log.info(pc.red(`⚠️  Some files failed to update - see errors above`));
    }

    // Show follow-up commands
    log.info('');
    log.info(pc.bold('Next steps:'));
    log.info(`    ${pc.cyan('psi verify')}                     Verify all changes were applied correctly`);
    log.info(`    ${pc.cyan('psi summary')}                    View updated database summary and tree hash`);
    log.info(`    ${pc.cyan('psi replicate --dest <path>')}    Create a backup copy of your updated database`);

    await exit(failedCount > 0 ? 1 : 0);
}