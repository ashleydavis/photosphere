import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { loadDatabase, IBaseCommandOptions, ICommandContext, resolveKeyPath } from "../lib/init-cmd";
import { formatBytes } from "../lib/format";
import { verify, verifyDatabaseFiles, IDatabaseFileVerifyResult } from "api";
import { IStorageDescriptor } from "storage";
import { getS3Config } from "../lib/config";

export interface IVerifyCommandOptions extends IBaseCommandOptions {
    //
    // Force full verification (bypass cached hash optimization).
    //
    full?: boolean;

    //
    // Path to a specific file or directory to verify (instead of entire database).
    //
    path?: string;
}

//
// Command that verifies the integrity of the Photosphere media file database.
//
export async function verifyCommand(context: ICommandContext, options: IVerifyCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;
    const { metadataStorage, assetStorage, databaseDir, metadataCollection } = await loadDatabase(options.db, options, true, uuidGenerator, timestampProvider, sessionId);


    // Create storage descriptor for passing to workers
    const resolvedKeyPath = await resolveKeyPath(options.key);
    const storageDescriptor: IStorageDescriptor = {
        dbDir: databaseDir,
        encryptionKeyPath: resolvedKeyPath
    };
    
    // Get S3 config to pass to workers (needed for S3-hosted storage)
    const s3Config = await getS3Config();

    //
    // First, verify database files (metadata and sort index files) when verifying the full database.
    //
    let dbFileResult: IDatabaseFileVerifyResult | undefined;
    if (!options.path) {
        writeProgress('🗄️  Verifying database files...');
        dbFileResult = await verifyDatabaseFiles(metadataStorage, assetStorage, (progress) => {
            writeProgress(`🔍 ${progress}`);
        });
    }
    
    //
    // Then, verify asset files.
    //
    writeProgress('Verifying assets...');
    
    const result = await verify(storageDescriptor, metadataStorage, context.taskQueueProvider, metadataCollection, {
        full: options.full,
        pathFilter: options.path,
        s3Config
    }, (progress) => {
        writeProgress(`🔍 ${progress}`);
    });

    clearProgressMessage(); // Flush the progress message.

    log.info(options.path 
        ? `Verified files matching: ${options.path}` 
        : `Asset files verified.`);
    log.info('');
    
    log.info(`Files imported:   ${pc.cyan(result.totalImports.toString())}`);
    log.info(`Total files:      ${pc.cyan(result.totalFiles.toString())}`);
    log.info(`Total size:       ${pc.cyan(formatBytes(result.totalSize))}`);
    log.info(`Files processed:  ${pc.cyan(result.filesProcessed.toString())}`);
    log.info(`Nodes processed:  ${pc.cyan(result.nodesProcessed.toString())}`);
    log.info(`Unmodified:       ${pc.green(result.numUnmodified.toString())}`);
    log.info(`Modified:         ${result.modified.length > 0 ? pc.red(result.modified.length.toString()) : pc.green('0')}`);
    log.info(`New:              ${result.new.length > 0 ? pc.yellow(result.new.length.toString()) : pc.green('0')}`);
    log.info(`Removed:          ${result.removed.length > 0 ? pc.red(result.removed.length.toString()) : pc.green('0')}`);
    log.info(`Failures:         ${result.numFailures > 0 ? pc.red(result.numFailures.toString()) : pc.green('0')}`);
    log.info(`Record mismatches: ${(result.recordMismatches?.length ?? 0) > 0 ? pc.red((result.recordMismatches?.length ?? 0).toString()) : pc.green('0')}`);

    // Show details for problematic files
    if (result.modified.length > 0) {
        log.info('');
        log.info(pc.red(`Modified files:`));
        result.modified.forEach(file => {
            log.info(`  ${pc.red('●')} ${file}`);
        });
    }
    
    if (result.new.length > 0) {
        log.info('');
        log.info(pc.yellow(`New files:`));
        result.new.forEach(file => {
            log.info(`  ${pc.yellow('+')} ${file}`);
        });
    }
    
    if (result.removed.length > 0) {
        log.info('');
        log.info(pc.red(`Removed files:`));
        result.removed.forEach(file => {
            log.info(`  ${pc.red('-')} ${file}`);
        });
    }

    if ((result.recordMismatches?.length ?? 0) > 0) {
        log.info('');
        log.info(pc.red(`Asset record mismatches (missing or wrong id/hash):`));
        result.recordMismatches!.forEach(path => {
            log.info(`  ${pc.red('●')} ${path}`);
        });
    }

    log.info('');
    
    //
    // Database file summary (only when we ran database file verification, i.e. full verify without path)
    //
    if (dbFileResult !== undefined) {
        log.info(pc.bold('Database files:'));
        log.info(`  Total files:    ${pc.cyan(dbFileResult.totalFiles.toString())}`);
        log.info(`  Total size:     ${pc.cyan(formatBytes(dbFileResult.totalSize))}`);
        log.info(`  Valid files:    ${dbFileResult.validFiles === dbFileResult.totalFiles ? pc.green(dbFileResult.validFiles.toString()) : pc.yellow(dbFileResult.validFiles.toString())}`);
        log.info(`  Invalid files:  ${dbFileResult.invalidFiles.length > 0 ? pc.red(dbFileResult.invalidFiles.length.toString()) : pc.green('0')}`);
        
        // Show details for invalid database files
        if (dbFileResult.errors.length > 0) {
            log.info('');
            log.info(pc.red(`Invalid database files:`));
            for (const { file, error } of dbFileResult.errors) {
                log.info(`  ${pc.red('●')} ${file}`);
                log.info(`    ${pc.gray(error)}`);
            }
        }
        log.info('');
    }
    
    //
    // Summary
    //
    const dbFilesOk = dbFileResult === undefined || dbFileResult.invalidFiles.length === 0;
    const assetFilesOk = result.modified.length === 0 && result.new.length === 0 && result.removed.length === 0 && result.numFailures === 0 && (result.recordMismatches?.length ?? 0) === 0;
    
    if (dbFilesOk && assetFilesOk) {
        log.info(pc.green(`✅ Database verification passed - all files are intact`));
    }
    else {
        if (dbFileResult !== undefined && !dbFilesOk) {
            log.info(pc.red(`❌ Database file verification failed - ${dbFileResult.invalidFiles.length} file(s) have issues`));
        }
        if (!assetFilesOk) {
            log.info(pc.yellow(`⚠️ Asset file verification found issues - see details above`));
        }
        if ((result.recordMismatches?.length ?? 0) > 0) {
            log.info(pc.red(`❌ Asset record verification failed - ${result.recordMismatches!.length} asset(s) have missing or wrong database record`));
        }
    }

    // Show follow-up commands
    log.info('');
    log.info(pc.bold('Next steps:'));
    const hasProblems = (dbFileResult?.invalidFiles.length ?? 0) > 0 || result.modified.length > 0 || result.new.length > 0 || result.removed.length > 0 || result.numFailures > 0 || (result.recordMismatches?.length ?? 0) > 0;
    if (hasProblems) {
        log.info(pc.gray(`    # Fix database issues by restoring from source`));
        log.info(`    psi repair --source <backup-db-path>`);
        log.info('');
    }
    else {
        log.info(pc.gray(`    # Create a backup copy of your database`));
        log.info(`    psi replicate --db ${databaseDir} --dest <other-db-path>`);
        log.info('');
        log.info(pc.gray(`    # Synchronize changes between two databases that have been independently changed`));
        log.info(`    psi sync --db ${databaseDir} --dest <other-db-path>`);
        log.info('');
        log.info(pc.gray(`    # Compare this database with another location`));
        log.info(`    psi compare --db ${databaseDir} --dest <other-db-path>`);
        log.info('');
        log.info(pc.gray(`    # View database summary and tree hash`));
        log.info(`    psi summary`);
    }

    await exit(0);
}
